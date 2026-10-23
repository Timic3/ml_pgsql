#include "convert.h"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <locale.h>

namespace mlpg
{
    namespace
    {
        char     g_nullSentinel;
        locale_t g_cLocale = nullptr;  // "C" numeric conventions regardless of the server's locale

        locale_t CLocale()
        {
            if (!g_cLocale)
                g_cLocale = newlocale(LC_ALL_MASK, "C", static_cast<locale_t>(nullptr));
            return g_cLocale;
        }

        constexpr int    kMaxArrayDepth = 6;          // PostgreSQL's MAXDIM
        constexpr size_t kMaxArrayLength = 10000000;  // guards against {[1e9] = 1}
        constexpr size_t kMaxParamBytes = 1u << 30;   // protocol message limit

        void SetError(char* error, size_t size, const char* fmt, const char* arg = "")
        {
            snprintf(error, size, fmt, arg);
        }

        // Shortest text that round-trips, integers without exponent or fraction.
        size_t FormatNumber(double d, char* buf, size_t size)
        {
            const char* special = nullptr;
            if (std::isnan(d))
                special = "NaN";
            else if (std::isinf(d))
                special = d > 0 ? "Infinity" : "-Infinity";
            if (special)
            {
                const size_t n = strlen(special);
                memcpy(buf, special, n);
                return n;
            }
            if (d == std::floor(d) && std::fabs(d) < 9.2e18)
            {
                const std::to_chars_result r = std::to_chars(buf, buf + size, static_cast<long long>(d));
                return static_cast<size_t>(r.ptr - buf);
            }
            // Shortest of %.15g..%.17g that reads back as the same double.
            const locale_t previous = uselocale(CLocale());
            int            n = 0;
            for (int precision = 15; precision <= 17; ++precision)
            {
                n = snprintf(buf, size, "%.*g", precision, d);
                if (strtod_l(buf, nullptr, CLocale()) == d)
                    break;
            }
            uselocale(previous);
            return n > 0 ? static_cast<size_t>(n) : 0;
        }

        bool AppendValue(Statement& st, const char* data, size_t len, char* error, size_t errorSize)
        {
            if (st.paramData.size() + len + 1 > kMaxParamBytes)
            {
                SetError(error, errorSize, "parameters exceed the 1 GB protocol limit");
                return false;
            }
            st.paramOffsets.push_back(static_cast<int32_t>(st.paramData.size()));
            st.paramData.append(data, len);
            st.paramData.push_back('\0');
            return true;
        }

        int AbsIndex(lua_State* L, int idx) { return (idx > 0 || idx <= LUA_REGISTRYINDEX) ? idx : lua_gettop(L) + idx + 1; }

        bool IsNull(lua_State* L, int idx)
        {
            const int t = lua_type(L, idx);
            return t == LUA_TNIL || (t == LUA_TLIGHTUSERDATA && lua_touserdata(L, idx) == NullSentinel());
        }

        // Highest positive integer key of an array-like table. Rejects other keys.
        bool ArrayLength(lua_State* L, int idx, size_t& length, char* error, size_t errorSize)
        {
            length = 0;
            lua_pushnil(L);
            while (lua_next(L, idx))
            {
                const bool   isNumber = lua_type(L, -2) == LUA_TNUMBER;
                const double k = isNumber ? lua_tonumber(L, -2) : 0;
                lua_settop(L, -2);  // pop value, keep key
                if (!isNumber || k < 1 || k != std::floor(k) || k > static_cast<double>(kMaxArrayLength))
                {
                    lua_settop(L, -2);
                    SetError(error, errorSize, "table parameters must be arrays (keys 1..n); use toJSON() for objects");
                    return false;
                }
                length = std::max(length, static_cast<size_t>(k));
            }
            return true;
        }

        // Appends a PostgreSQL array literal ({1,2,"three",NULL,{...}}) for the table at idx.
        bool EncodeArray(lua_State* L, int idx, std::string& out, int depth, char* error, size_t errorSize)
        {
            if (depth > kMaxArrayDepth)
            {
                SetError(error, errorSize, "array parameter nested too deeply (max 6 dimensions, or a cyclic table)");
                return false;
            }
            if (!lua_checkstack(L, 6))
            {
                SetError(error, errorSize, "Lua stack exhausted while encoding an array parameter");
                return false;
            }
            size_t length;
            if (!ArrayLength(L, idx, length, error, errorSize))
                return false;

            out.push_back('{');
            for (size_t i = 1; i <= length; ++i)
            {
                if (i > 1)
                    out.push_back(',');
                lua_rawgeti(L, idx, static_cast<int>(i));
                const int top = lua_gettop(L);
                bool      ok = true;
                switch (lua_type(L, top))
                {
                    case LUA_TNIL:
                        out += "NULL";
                        break;
                    case LUA_TBOOLEAN:
                        out += lua_toboolean(L, top) ? "true" : "false";
                        break;
                    case LUA_TNUMBER:
                    {
                        char         buf[64];
                        const size_t n = FormatNumber(lua_tonumber(L, top), buf, sizeof(buf));
                        out.append(buf, n);
                        break;
                    }
                    case LUA_TSTRING:
                    {
                        size_t      len;
                        const char* s = lua_tolstring(L, top, &len);
                        if (memchr(s, '\0', len))
                        {
                            SetError(error, errorSize, "string inside an array parameter contains a NUL byte");
                            ok = false;
                            break;
                        }
                        out.push_back('"');
                        for (size_t k = 0; k < len; ++k)
                        {
                            if (s[k] == '"' || s[k] == '\\')
                                out.push_back('\\');
                            out.push_back(s[k]);
                        }
                        out.push_back('"');
                        break;
                    }
                    case LUA_TTABLE:
                        ok = EncodeArray(L, top, out, depth + 1, error, errorSize);
                        break;
                    case LUA_TLIGHTUSERDATA:
                        if (lua_touserdata(L, top) == NullSentinel())
                        {
                            out += "NULL";
                            break;
                        }
                        [[fallthrough]];
                    default:
                        SetError(error, errorSize, "unsupported value of type '%s' inside an array parameter", lua_typename(L, lua_type(L, top)));
                        ok = false;
                }
                lua_settop(L, top - 1);
                if (!ok)
                    return false;
                if (out.size() > kMaxParamBytes)
                {
                    SetError(error, errorSize, "parameters exceed the 1 GB protocol limit");
                    return false;
                }
            }
            out.push_back('}');
            return true;
        }

        // Skips whitespace and SQL comments; returns the first keyword (uppercased, max 15 chars).
        void FirstKeyword(const char* sql, size_t len, char* word, size_t wordSize)
        {
            size_t i = 0;
            for (;;)
            {
                while (i < len && (isspace(static_cast<unsigned char>(sql[i])) || sql[i] == ';'))
                    ++i;
                if (i + 1 < len && sql[i] == '-' && sql[i + 1] == '-')
                {
                    while (i < len && sql[i] != '\n')
                        ++i;
                    continue;
                }
                if (i + 1 < len && sql[i] == '/' && sql[i + 1] == '*')
                {
                    // PostgreSQL block comments nest
                    int    depth = 1;
                    size_t k = i + 2;
                    while (k < len && depth > 0)
                    {
                        if (k + 1 < len && sql[k] == '/' && sql[k + 1] == '*')
                        {
                            ++depth;
                            k += 2;
                        }
                        else if (k + 1 < len && sql[k] == '*' && sql[k + 1] == '/')
                        {
                            --depth;
                            k += 2;
                        }
                        else
                            ++k;
                    }
                    i = k;
                    continue;
                }
                break;
            }
            size_t n = 0;
            while (i < len && n + 1 < wordSize && isalpha(static_cast<unsigned char>(sql[i])))
                word[n++] = static_cast<char>(toupper(static_cast<unsigned char>(sql[i++])));
            word[n] = '\0';
        }

        // ---------------------------------------------------------------------------
        // Result conversion
        // ---------------------------------------------------------------------------

        enum class Kind : uint8_t
        {
            Text,
            Bool,
            Int,      // int2, int4, oid: always fits a double
            Int8,
            Float,
            Numeric,
            Bytea,
            Array,
        };

        struct Column
        {
            Kind kind = Kind::Text;
            Kind element = Kind::Text;  // for arrays
        };

        Column Classify(Oid oid)
        {
            switch (oid)
            {
                case 16: return {Kind::Bool};
                case 17: return {Kind::Bytea};
                case 20: return {Kind::Int8};
                case 21:
                case 23:
                case 26: return {Kind::Int};
                case 700:
                case 701: return {Kind::Float};
                case 1700: return {Kind::Numeric};
                // arrays
                case 1000: return {Kind::Array, Kind::Bool};
                case 1001: return {Kind::Array, Kind::Bytea};
                case 1005:
                case 1007:
                case 1028: return {Kind::Array, Kind::Int};
                case 1016: return {Kind::Array, Kind::Int8};
                case 1021:
                case 1022: return {Kind::Array, Kind::Float};
                case 1231: return {Kind::Array, Kind::Numeric};
                case 1002:  // char[]
                case 1003:  // name[]
                case 1009:  // text[]
                case 1014:  // bpchar[]
                case 1015:  // varchar[]
                case 199:   // json[]
                case 3807:  // jsonb[]
                case 2951:  // uuid[]
                case 1115:  // timestamp[]
                case 1182:  // date[]
                case 1183:  // time[]
                case 1185:  // timestamptz[]
                case 1187:  // interval[]
                case 1270:  // timetz[]
                case 1041:  // inet[]
                case 651:   // cidr[]
                case 1040:  // macaddr[]
                    return {Kind::Array, Kind::Text};
                default: return {Kind::Text};
            }
        }

        // Locale-independent (PostgreSQL always prints '.'); accepts NaN and [-]Infinity.
        bool ParseDouble(const char* s, size_t len, double& out)
        {
            char        small[64];
            std::string large;
            const char* text;
            if (len < sizeof(small))
            {
                memcpy(small, s, len);
                small[len] = '\0';
                text = small;
            }
            else
            {
                large.assign(s, len);  // numeric values can have thousands of digits
                text = large.c_str();
            }
            char* end = nullptr;
            out = strtod_l(text, &end, CLocale());
            return len > 0 && end == text + len;
        }

        int HexValue(char c)
        {
            if (c >= '0' && c <= '9')
                return c - '0';
            if (c >= 'a' && c <= 'f')
                return c - 'a' + 10;
            if (c >= 'A' && c <= 'F')
                return c - 'A' + 10;
            return -1;
        }

        std::string g_scratch;  // main thread only

        void PushBytea(lua_State* L, const char* s, size_t len)
        {
            if (len >= 2 && s[0] == '\\' && s[1] == 'x' && (len % 2) == 0)
            {
                g_scratch.resize((len - 2) / 2);
                bool ok = true;
                for (size_t i = 2, o = 0; i < len; i += 2, ++o)
                {
                    const int hi = HexValue(s[i]), lo = HexValue(s[i + 1]);
                    if (hi < 0 || lo < 0)
                    {
                        ok = false;
                        break;
                    }
                    g_scratch[o] = static_cast<char>((hi << 4) | lo);
                }
                if (ok)
                {
                    lua_pushlstring(L, g_scratch.data(), g_scratch.size());
                    if (g_scratch.capacity() > (1u << 20))
                        std::string().swap(g_scratch);
                    return;
                }
            }
            // bytea_output = 'escape' (or something unexpected): let libpq decode it
            std::string    copy(s, len);
            size_t         outLen = 0;
            unsigned char* decoded = PQunescapeBytea(reinterpret_cast<const unsigned char*>(copy.c_str()), &outLen);
            if (decoded)
            {
                lua_pushlstring(L, reinterpret_cast<const char*>(decoded), outLen);
                PQfreemem(decoded);
            }
            else
                lua_pushlstring(L, s, len);
        }

        void PushScalar(lua_State* L, const char* s, size_t len, Kind kind, const ConvOptions& conv)
        {
            switch (kind)
            {
                case Kind::Bool:
                    lua_pushboolean(L, len > 0 && (s[0] == 't' || s[0] == 'T'));
                    return;
                case Kind::Int:
                case Kind::Int8:
                {
                    if (kind == Kind::Int8 && conv.int64 == Int64Mode::String)
                        break;
                    long long v = 0;
                    auto      r = std::from_chars(s, s + len, v);
                    if (r.ec != std::errc() || r.ptr != s + len)
                        break;
                    constexpr long long kSafe = 1LL << 53;
                    if (kind == Kind::Int8 && conv.int64 == Int64Mode::Auto && (v > kSafe || v < -kSafe))
                        break;
                    lua_pushnumber(L, static_cast<lua_Number>(v));
                    return;
                }
                case Kind::Float:
                case Kind::Numeric:
                {
                    if (kind == Kind::Numeric && conv.numeric == NumericMode::String)
                        break;
                    double d;
                    if (!ParseDouble(s, len, d))
                        break;
                    lua_pushnumber(L, d);
                    return;
                }
                case Kind::Bytea:
                    PushBytea(L, s, len);
                    return;
                default:
                    break;
            }
            lua_pushlstring(L, s, len);
        }

        // Parser for PostgreSQL's array text output: [1:2]={{1,2},{3,NULL}} etc.
        class ArrayParser
        {
        public:
            ArrayParser(lua_State* L, const char* s, size_t len, Kind element, const ConvOptions& conv)
                : m_L(L), m_p(s), m_end(s + len), m_element(element), m_conv(conv)
            {
            }

            bool Parse()
            {
                if (m_p < m_end && *m_p == '[')  // explicit bounds decoration
                {
                    while (m_p < m_end && *m_p != '=')
                        ++m_p;
                    if (m_p == m_end)
                        return false;
                    ++m_p;
                }
                return ParseLevel(0) && m_p == m_end;
            }

        private:
            bool ParseLevel(int depth)
            {
                if (depth > kMaxArrayDepth || m_p >= m_end || *m_p != '{' || !lua_checkstack(m_L, 4))
                    return false;
                ++m_p;
                lua_createtable(m_L, 0, 0);
                const int table = lua_gettop(m_L);
                int       index = 1;
                if (m_p < m_end && *m_p == '}')
                {
                    ++m_p;
                    return true;
                }
                for (;;)
                {
                    if (m_p >= m_end)
                        return false;
                    if (*m_p == '{')
                    {
                        if (!ParseLevel(depth + 1))
                            return false;
                        lua_rawseti(m_L, table, index);
                    }
                    else if (*m_p == '"')
                    {
                        ++m_p;
                        m_buf.clear();
                        while (m_p < m_end && *m_p != '"')
                        {
                            if (*m_p == '\\' && m_p + 1 < m_end)
                                ++m_p;
                            m_buf.push_back(*m_p++);
                        }
                        if (m_p >= m_end)
                            return false;
                        ++m_p;  // closing quote
                        PushScalar(m_L, m_buf.data(), m_buf.size(), m_element, m_conv);
                        lua_rawseti(m_L, table, index);
                    }
                    else
                    {
                        const char* start = m_p;
                        while (m_p < m_end && *m_p != ',' && *m_p != '}')
                            ++m_p;
                        const size_t len = static_cast<size_t>(m_p - start);
                        if (!(len == 4 && strncasecmp(start, "NULL", 4) == 0))
                        {
                            PushScalar(m_L, start, len, m_element, m_conv);
                            lua_rawseti(m_L, table, index);
                        }
                    }
                    ++index;
                    if (m_p >= m_end)
                        return false;
                    if (*m_p == ',')
                    {
                        ++m_p;
                        continue;
                    }
                    if (*m_p == '}')
                    {
                        ++m_p;
                        return true;
                    }
                    return false;
                }
            }

            lua_State*         m_L;
            const char*        m_p;
            const char*        m_end;
            Kind               m_element;
            const ConvOptions& m_conv;
            std::string        m_buf;
        };

        void PushValue(lua_State* L, const char* s, size_t len, const Column& col, const ConvOptions& conv)
        {
            if (col.kind != Kind::Array)
            {
                PushScalar(L, s, len, col.kind, conv);
                return;
            }
            const int   top = lua_gettop(L);
            ArrayParser parser(L, s, len, col.element, conv);
            if (parser.Parse())
            {
                lua_settop(L, top + 1);  // the outermost table
                return;
            }
            lua_settop(L, top);
            lua_pushlstring(L, s, len);  // unexpected format: hand over the raw text
        }

        double AffectedRows(const PGresult* res)
        {
            if (!res)
                return 0;
            const char* tuples = PQcmdTuples(const_cast<PGresult*>(res));
            return (tuples && *tuples) ? strtod(tuples, nullptr) : 0;
        }

        void PushRows(lua_State* L, const PGresult* res, const ConvOptions& conv)
        {
            const int rows = res ? PQntuples(res) : 0;
            const int cols = res ? PQnfields(res) : 0;
            lua_createtable(L, rows, 0);
            if (rows > 0 && cols == 0)  // "SELECT" / "SELECT FROM t": rows without columns
            {
                for (int r = 0; r < rows; ++r)
                {
                    lua_createtable(L, 0, 0);
                    lua_rawseti(L, -2, r + 1);
                }
                return;
            }
            if (rows == 0 || cols == 0 || !lua_checkstack(L, cols + 8))
                return;

            const int rowsIndex = lua_gettop(L);
            // Column metadata lives on the C stack, or in a Lua-owned block for wide results,
            // so nothing here can throw.
            Column  small[64];
            Column* columns = small;
            if (cols > 64)
                columns = static_cast<Column*>(lua_newuserdata(L, sizeof(Column) * static_cast<size_t>(cols)));
            const int keyBase = lua_gettop(L) + 1;
            // Column names are pushed once and reused as keys: no string hashing per cell.
            for (int c = 0; c < cols; ++c)
            {
                lua_pushstring(L, PQfname(res, c));
                columns[c] = Classify(PQftype(res, c));
            }
            for (int r = 0; r < rows; ++r)
            {
                lua_createtable(L, 0, cols);
                for (int c = 0; c < cols; ++c)
                {
                    if (PQgetisnull(res, r, c))
                        continue;  // SQL NULL -> absent key (nil), like MTA's dbPoll
                    lua_pushvalue(L, keyBase + c);
                    PushValue(L, PQgetvalue(res, r, c), static_cast<size_t>(PQgetlength(res, r, c)), columns[c], conv);
                    lua_rawset(L, -3);
                }
                lua_rawseti(L, rowsIndex, r + 1);
            }
            lua_settop(L, rowsIndex);
        }
    }

    void* NullSentinel() { return &g_nullSentinel; }

    void ShutdownConversion()
    {
        if (g_cLocale)
            freelocale(g_cLocale);
        g_cLocale = nullptr;
        std::string().swap(g_scratch);
    }

    bool AppendParam(lua_State* L, int idx, Statement& st, char* error, size_t errorSize)
    {
        idx = AbsIndex(L, idx);
        if (IsNull(L, idx))
        {
            st.paramOffsets.push_back(-1);
            return true;
        }
        switch (lua_type(L, idx))
        {
            case LUA_TBOOLEAN:
                return lua_toboolean(L, idx) ? AppendValue(st, "true", 4, error, errorSize) : AppendValue(st, "false", 5, error, errorSize);
            case LUA_TNUMBER:
            {
                char         buf[64];
                const size_t n = FormatNumber(lua_tonumber(L, idx), buf, sizeof(buf));
                return AppendValue(st, buf, n, error, errorSize);
            }
            case LUA_TSTRING:
            {
                size_t      len;
                const char* s = lua_tolstring(L, idx, &len);
                if (memchr(s, '\0', len))
                {
                    SetError(error, errorSize, "string parameter contains a NUL byte (use pgBytea() for binary data)");
                    return false;
                }
                return AppendValue(st, s, len, error, errorSize);
            }
            case LUA_TTABLE:
            {
                std::string literal;
                if (!EncodeArray(L, idx, literal, 1, error, errorSize))
                    return false;
                return AppendValue(st, literal.data(), literal.size(), error, errorSize);
            }
            default:
                SetError(error, errorSize, "unsupported parameter type '%s'", lua_typename(L, lua_type(L, idx)));
                return false;
        }
    }

    bool NeedsSimpleProtocol(const char* sql, size_t len)
    {
        if (IsCopy(sql, len))
            return true;
        // A ';' followed by anything but whitespace means several commands. A ';' inside a
        // string literal only costs pipelining, never correctness.
        const char* semi = static_cast<const char*>(memchr(sql, ';', len));
        if (!semi)
            return false;
        for (const char* p = semi + 1; p < sql + len; ++p)
            if (!isspace(static_cast<unsigned char>(*p)))
                return true;
        return false;
    }

    bool IsCopy(const char* sql, size_t len)
    {
        char word[16];
        FirstKeyword(sql, len, word, sizeof(word));
        return strcmp(word, "COPY") == 0;
    }

    bool IsTransactionStart(const char* sql, size_t len)
    {
        char word[16];
        FirstKeyword(sql, len, word, sizeof(word));
        return strcmp(word, "BEGIN") == 0 || strcmp(word, "START") == 0;
    }

    bool IsTransactionControl(const char* sql, size_t len)
    {
        char word[16];
        FirstKeyword(sql, len, word, sizeof(word));
        static const char* const kWords[] = {"BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE", "PREPARE"};
        for (const char* w : kWords)
            if (strcmp(word, w) == 0)
                return true;
        return false;
    }

    int PushOutcomeUnchecked(lua_State* L, Job& job);

    int PushOutcome(lua_State* L, Job& job)
    {
        // Conversion allocates scratch strings; out of memory must not throw into Lua.
        const int base = lua_gettop(L);
        try
        {
            return PushOutcomeUnchecked(L, job);
        }
        catch (const std::exception&)
        {
            lua_settop(L, base);
            lua_pushboolean(L, 0);
            lua_pushstring(L, "out of memory while converting the result");
            lua_pushnil(L);
            if (!job.transaction)
                return 3;
            lua_pushnil(L);
            return 4;
        }
    }

    int PushOutcomeUnchecked(lua_State* L, Job& job)
    {
        if (!job.ok)
        {
            lua_pushboolean(L, 0);
            lua_pushlstring(L, job.error.data(), job.error.size());
            if (job.sqlstate[0])
                lua_pushstring(L, job.sqlstate);
            else
                lua_pushnil(L);
            if (!job.transaction)
                return 3;
            if (job.failedStatement > 0)
                lua_pushnumber(L, job.failedStatement);
            else
                lua_pushnil(L);
            return 4;
        }

        if (!job.transaction)
        {
            const PGresult* res = job.stmts[0].result.get();
            PushRows(L, res, job.conv);
            lua_pushnil(L);
            lua_pushnumber(L, AffectedRows(res));
            return 3;
        }

        const int count = static_cast<int>(job.stmts.size());
        lua_createtable(L, count, 0);
        for (int i = 0; i < count; ++i)
        {
            PushRows(L, job.stmts[i].result.get(), job.conv);
            lua_rawseti(L, -2, i + 1);
        }
        lua_pushnil(L);
        lua_createtable(L, count, 0);
        for (int i = 0; i < count; ++i)
        {
            lua_pushnumber(L, AffectedRows(job.stmts[i].result.get()));
            lua_rawseti(L, -2, i + 1);
        }
        return 3;
    }
}

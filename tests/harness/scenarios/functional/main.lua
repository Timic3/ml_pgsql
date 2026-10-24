-- Scenario 1: functional coverage of every API function, option and type conversion.
local db, dbStr, dbNum, dbEsc
local tbl = T.uniq("func")
local q = function(sql, ...) return pgQuerySync(db, sql, ...) end
local NaN = 0 / 0
local INF = math.huge

local function row1(sql, ...)
    local rows, err, extra = pgQuerySync(db, sql, ...)
    if not T.ok(rows, "query failed: " .. tostring(sql) .. ": " .. tostring(err)) then return {} end
    return rows[1] or {}, rows, extra
end

local function allBytes()
    local t = {}
    for i = 0, 255 do t[#t + 1] = string.char(i) end
    return table.concat(t)
end

T.run({
    { "pgVersion / connect options validation", function()
        local v, lib = pgVersion()
        T.eq(v, "1.0.1", "module version")
        T.ok(type(lib) == "number" and lib >= 170000, "libpq version " .. tostring(lib))

        db = pgConnect(CONNINFO, { applicationName = "func-main" })
        T.ok(db, "default connect")
        T.eq(getmetatable(db), "ml_pgsql.connection", "metatable is protected")
        T.match(tostring(db), "^pgsql%-connection #%d+$", "tostring")

        dbStr = pgConnect(CONNINFO, { int64 = "string", numeric = "string", poolSize = 2, pipeline = true, batchSize = 8,
            maxQueue = 1000, connectTimeout = 5000, queryTimeout = 0, syncTimeout = 10000, drainTimeout = 2000,
            lazy = false, applicationName = "func-str" })
        T.ok(dbStr, "connect with every option")
        dbNum = pgConnect(CONNINFO, { int64 = "number", numeric = "number", lazy = true, applicationName = "func-num" })
        T.ok(dbNum, "lazy connect")
        dbEsc = pgConnect(CONNINFO .. " options='-c bytea_output=escape'", { applicationName = "func-esc" })
        T.ok(dbEsc, "connect with bytea_output=escape")

        -- programming errors raise
        T.raises("poolSize", pgConnect, CONNINFO, { poolSize = 0 })
        T.raises("poolSize", pgConnect, CONNINFO, { poolSize = 65 })
        T.raises("poolSize", pgConnect, CONNINFO, { poolSize = NaN })
        T.raises("must be a number", pgConnect, CONNINFO, { poolSize = "2" })
        T.raises("batchSize", pgConnect, CONNINFO, { batchSize = 1001 })
        T.raises("maxQueue", pgConnect, CONNINFO, { maxQueue = 0 })
        T.raises("connectTimeout", pgConnect, CONNINFO, { connectTimeout = 50 })
        T.raises("syncTimeout", pgConnect, CONNINFO, { syncTimeout = 0 })
        T.raises("must be a boolean", pgConnect, CONNINFO, { lazy = 1 })
        T.raises("must be a boolean", pgConnect, CONNINFO, { pipeline = "yes" })
        T.raises("int64", pgConnect, CONNINFO, { int64 = "bigint" })
        T.raises("numeric", pgConnect, CONNINFO, { numeric = "decimal" })
        T.raises("must be a string", pgConnect, CONNINFO, { applicationName = 5 })
        T.raises("bad argument #1", pgConnect, nil)
        T.raises("bad argument #2", pgConnect, CONNINFO, "notatable")
        T.raises("NUL byte", pgConnect, "host=x\0y")

        -- runtime problems are returned
        local bad, err = pgConnect("host='unterminated")
        T.eq(bad, false, "invalid conninfo returns false")
        T.match(err, "invalid connection string", "invalid conninfo message")
        local bad2, err2 = pgConnect("postgresql://%zz")
        T.eq(bad2, false, "invalid URI returns false")
        T.ok(type(err2) == "string", "invalid URI message")
        local uri = ("postgresql://mta:mta@%s:%d/mta?sslmode=disable"):format(PGHOST, PGPORT)
        local dbUri = pgConnect(uri, { applicationName = "func-uri" })
        T.ok(dbUri, "URI conninfo")
        if dbUri then
            T.eq(pgQuerySync(dbUri, "SELECT current_user AS u")[1].u, "mta", "URI query")
            T.eq(pgClose(dbUri), true, "close URI conn")
        end
        -- sslmode=prefer against a server without SSL (exercises libpq's TLS negotiation)
        local dbSsl = pgConnect(CONNINFO:gsub("sslmode=%w+", "sslmode=prefer"), { applicationName = "func-ssl" })
        T.ok(dbSsl, "sslmode=prefer")
        if dbSsl then T.eq(pgQuerySync(dbSsl, "SELECT 1 AS x")[1].x, 1, "prefer query"); pgClose(dbSsl) end

        T.eq(T.backends("func-main"), 1, "application_name applied")
    end },

    { "schema setup with a multi-statement pgExec", function()
        T.ok(pgExec(db, ([[
            CREATE TABLE %s (id serial PRIMARY KEY, k text UNIQUE, v int, b bytea, CHECK (v IS NULL OR v >= 0));
            CREATE TABLE %s_fk (id int REFERENCES %s(id));
            CREATE TABLE %s_def (k int UNIQUE DEFERRABLE INITIALLY DEFERRED);
            INSERT INTO %s (k, v) VALUES ('seed', 1);
        ]]):format(tbl, tbl, tbl, tbl, tbl)), "pgExec accepted")
        local rows = T.query(db, "SELECT count(*)::int AS n FROM " .. tbl)
        T.eq(rows, { { n = 1 } }, "multi-statement pgExec ran")
    end },

    { "result types: bool / int / int8 modes / oid", function()
        local r = row1("SELECT true AS t, false AS f, NULL::bool AS n, 32767::int2 AS i2max, (-32768)::int2 AS i2min, " ..
            "2147483647 AS i4max, (-2147483648)::int4 AS i4min, 4294967295::oid AS o, 'pg_class'::regclass::oid AS o2")
        T.eq(r, { t = true, f = false, i2max = 32767, i2min = -32768, i4max = 2147483647, i4min = -2147483648, o = 4294967295, o2 = 1259 }, "scalars")

        local sql = "SELECT 9007199254740992::int8 AS p53, 9007199254740993::int8 AS p53p1, (-9007199254740992)::int8 AS n53, " ..
            "(-9007199254740993)::int8 AS n53m1, 9223372036854775807::int8 AS max, (-9223372036854775808)::int8 AS min, 0::int8 AS z, (-1)::int8 AS m1"
        T.eq(row1(sql), { p53 = 9007199254740992, p53p1 = "9007199254740993", n53 = -9007199254740992, n53m1 = "-9007199254740993",
            max = "9223372036854775807", min = "-9223372036854775808", z = 0, m1 = -1 }, "int64 auto")
        T.eq(pgQuerySync(dbNum, sql)[1], { p53 = 2 ^ 53, p53p1 = 2 ^ 53, n53 = -2 ^ 53, n53m1 = -2 ^ 53, max = 2 ^ 63, min = -2 ^ 63, z = 0, m1 = -1 }, "int64 number")
        T.eq(pgQuerySync(dbStr, sql)[1], { p53 = "9007199254740992", p53p1 = "9007199254740993", n53 = "-9007199254740992", n53m1 = "-9007199254740993",
            max = "9223372036854775807", min = "-9223372036854775808", z = "0", m1 = "-1" }, "int64 string")
        T.eq(pgQuerySync(dbStr, "SELECT 5::int4 AS i, 5::int2 AS s")[1], { i = 5, s = 5 }, "int64=string leaves int4 alone")
        T.eq(row1("SELECT count(*) AS c FROM (VALUES (1),(2)) v"), { c = 2 }, "count(*) is int8 -> number")
    end },

    { "result types: float / numeric", function()
        local r = row1("SELECT 1.5::float8 AS a, 0.1::float4 AS b, 'NaN'::float8 AS nan, 'Infinity'::float8 AS inf, '-Infinity'::float4 AS ninf, " ..
            "1.7976931348623157e308::float8 AS big, 5e-324::float8 AS tiny, '-0'::float8 AS nz")
        T.eq(r.a, 1.5, "float8")
        T.eq(r.b, 0.1, "float4 shortest text")
        T.ok(r.nan ~= r.nan, "NaN")
        T.eq(r.inf, INF, "Infinity")
        T.eq(r.ninf, -INF, "-Infinity")
        T.eq(r.big, 1.7976931348623157e308, "max double")
        T.eq(r.tiny, 5e-324, "denormal")
        T.ok(r.nz == 0 and 1 / r.nz == -INF, "negative zero")

        local nsql = "SELECT 123.456::numeric AS a, 'NaN'::numeric AS b, 'Infinity'::numeric AS c, '-Infinity'::numeric AS d, " ..
            "12345678901234567890.123456789::numeric AS e, (0.1::numeric + 0.2::numeric) AS f, 1e-20::numeric AS g, 10::numeric(10,2) AS h"
        local n = row1(nsql)
        T.eq(n.a, 123.456, "numeric as number")
        T.ok(n.b ~= n.b, "numeric NaN")
        T.eq(n.c, INF, "numeric Infinity")
        T.eq(n.d, -INF, "numeric -Infinity")
        T.eq(n.e, 12345678901234567890.123456789, "big numeric approx")
        T.eq(n.f, 0.3, "0.1+0.2 numeric is exact 0.3")
        T.eq(n.g, 1e-20, "tiny numeric")
        T.eq(n.h, 10, "numeric(10,2)")
        T.eq(pgQuerySync(dbStr, nsql)[1], { a = "123.456", b = "NaN", c = "Infinity", d = "-Infinity", e = "12345678901234567890.123456789",
            f = "0.3", g = "0.00000000000000000001", h = "10.00" }, "numeric as string")
    end },

    { "result types: text-like, NULL, empty, duplicates", function()
        local r = row1("SELECT 'x'::text AS t, 'y'::varchar AS v, 'z'::char(3) AS c, '{\"a\": [1, 2]}'::json AS j, '{\"a\": 1}'::jsonb AS jb, " ..
            "'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid AS u, '2024-01-02 03:04:05'::timestamp AS ts, '1 day'::interval AS iv, " ..
            "'10.0.0.1'::inet AS ip, 'ünï©ødé 😀'::text AS uni, ''::text AS empty, NULL::text AS nul, 'pg'::name AS nm")
        T.eq(r, { t = "x", v = "y", c = "z  ", j = '{"a": [1, 2]}', jb = '{"a": 1}', u = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
            ts = "2024-01-02 03:04:05", iv = "1 day", ip = "10.0.0.1", uni = "ünï©ødé 😀", empty = "", nm = "pg" }, "text-like types")
        local rows, err, n = pgQuerySync(db, "SELECT 1 AS a WHERE false")
        T.eq(rows, {}, "no rows")
        T.eq(n, 0, "affected 0")
        T.eq(pgQuerySync(db, "SELECT 1 AS a, 2 AS a")[1], { a = 2 }, "duplicate column names: last wins")
        T.eq(pgQuerySync(db, "SELECT 1 AS \"weird key \"\" \"")[1], { ['weird key " '] = 1 }, "quoted column name")
        T.eq(pgQuerySync(db, "SELECT"), { {} }, "zero-column result keeps its row")
        local many = pgQuerySync(db, "SELECT g AS n, md5(g::text) AS h FROM generate_series(1, 20000) g")
        T.eq(#many, 20000, "20k rows")
        T.eq(many[20000].n, 20000, "last row")
        local big = string.rep("ab", 1024 * 1024)
        T.eq(pgQuerySync(db, "SELECT $1::text AS s", big)[1].s, big, "2 MB text round trip")
        local cols = {}
        for i = 1, 1000 do cols[i] = i .. " AS c" .. i end
        local wide = pgQuerySync(db, "SELECT " .. table.concat(cols, ","))
        T.eq(wide and wide[1].c1000, 1000, "1000 columns")
    end },

    { "bytea both directions (all 256 byte values)", function()
        local all = allBytes()
        local r = row1("SELECT $1::bytea AS b, length($1::bytea) AS n, ''::bytea AS e, NULL::bytea AS nul", pgBytea(all))
        T.eq(r.n, 256, "server saw 256 bytes")
        T.ok(r.b == all, "bytea round trip (hex output)")
        T.eq(r.e, "", "empty bytea")
        T.eq(pgBytea(""), "\\x", "pgBytea empty")
        T.eq(pgBytea("\0\255A"), "\\x00ff41", "pgBytea hex")
        local e = pgQuerySync(dbEsc, "SELECT $1::bytea AS b, current_setting('bytea_output') AS mode", pgBytea(all))
        T.eq(e and e[1].mode, "escape", "escape mode active")
        T.ok(e and e[1].b == all, "bytea round trip (escape output)")
        T.eq(row1("SELECT decode('00ff10', 'hex') AS b").b, "\0\255\16", "decode()")
        -- stored and read back
        T.ok(pgQuerySync(db, "UPDATE " .. tbl .. " SET b = $1 WHERE k = 'seed'", pgBytea(all)), "store bytea")
        T.ok(row1("SELECT b FROM " .. tbl .. " WHERE k = 'seed'").b == all, "stored bytea")
        T.raises("NUL byte", pgQuerySync, db, "SELECT $1::bytea", all)
    end },

    { "arrays from PostgreSQL", function()
        local r = row1([==[SELECT ARRAY[1,2,3] AS a, '{{1,2},{3,4}}'::int[] AS m, ARRAY[1,NULL,3] AS holes, '{}'::int[] AS empty,
            ARRAY[true,false,NULL] AS bools, ARRAY['NaN','Infinity','-Infinity',1.5]::float8[] AS floats,
            ARRAY[1, 9007199254740993, -9223372036854775808]::int8[] AS bigs, ARRAY[1.5, 2.25]::numeric[] AS nums,
            '{{{1,2},{3,4}},{{5,6},{7,8}}}'::int[] AS cube, '[0:2]={7,8,9}'::int[] AS lb,
            ARRAY[ARRAY['a',NULL],ARRAY['b','c']] AS t2, ARRAY['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid] AS uuids,
            ARRAY['{"a":1}'::json, '[1,"x\"y"]'::json] AS jsons, ARRAY['{"k": "v"}'::jsonb] AS jsonbs,
            ARRAY['\x00ff'::bytea, NULL, ''::bytea] AS byteas, ARRAY[1,2]::int2[] AS smalls, ARRAY['x']::varchar[] AS vc,
            ARRAY['pg_class']::name[] AS names, '{{{{{{1}}}}}}'::int[] AS six, ARRAY[point(1,2)] AS points,
            ARRAY[int4range(1,3)] AS ranges, ARRAY['2024-01-01'::date] AS dates]==])
        T.eq(r.a, { 1, 2, 3 }, "int[]")
        T.eq(r.m, { { 1, 2 }, { 3, 4 } }, "int[][]")
        T.eq(r.holes, { [1] = 1, [3] = 3 }, "NULL elements")
        T.eq(r.empty, {}, "empty array")
        T.eq(r.bools, { true, false }, "bool[]")
        T.ok(r.floats[1] ~= r.floats[1] and r.floats[2] == INF and r.floats[3] == -INF and r.floats[4] == 1.5, "float8[] specials " .. inspect(r.floats))
        T.eq(r.bigs, { 1, "9007199254740993", "-9223372036854775808" }, "int8[] auto")
        T.eq(r.nums, { 1.5, 2.25 }, "numeric[]")
        T.eq(r.cube, { { { 1, 2 }, { 3, 4 } }, { { 5, 6 }, { 7, 8 } } }, "3-D")
        T.eq(r.lb, { 7, 8, 9 }, "explicit lower bound")
        T.eq(r.t2, { { "a" }, { "b", "c" } }, "text[][] with NULL")
        T.eq(r.uuids, { "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11" }, "uuid[]")
        T.eq(r.jsons, { '{"a":1}', '[1,"x\\"y"]' }, "json[]")
        T.eq(r.jsonbs, { '{"k": "v"}' }, "jsonb[]")
        T.eq(r.byteas, { [1] = "\0\255", [3] = "" }, "bytea[]")
        T.eq(r.smalls, { 1, 2 }, "int2[]")
        T.eq(r.vc, { "x" }, "varchar[]")
        T.eq(r.names, { "pg_class" }, "name[]")
        T.eq(r.six, { { { { { { 1 } } } } } }, "6-D")
        T.eq(r.points, '{"(1,2)"}', "unknown element type -> raw text")
        T.eq(r.ranges, '{"[1,3)"}', "range[] -> raw text")
        T.eq(r.dates, { "2024-01-01" }, "date[]")
        T.eq(pgQuerySync(dbStr, "SELECT ARRAY[1,2]::int8[] AS a, ARRAY[1.5]::numeric[] AS n")[1], { a = { "1", "2" }, n = { "1.5" } }, "array element modes (string)")
    end },

    { "parameters: scalars", function()
        local r = row1("SELECT $1::int IS NULL AS a, $2::text IS NULL AS b, $3::bool AS c, $4::bool AS d, $5::text AS e, $6::text AS f, $7::int IS NULL AS g",
            nil, PG_NULL, true, false, "O'Reilly \"q\" \\ ünï 😀", "", nil)
        T.eq(r, { a = true, b = true, c = true, d = false, e = "O'Reilly \"q\" \\ ünï 😀", f = "", g = true }, "nil/PG_NULL/bool/string")
        T.eq(type(PG_NULL), "userdata", "PG_NULL is a light userdata")

        local nums = { 0, 1, -1, 42, -7, 2 ^ 31, -2 ^ 31, 2 ^ 53, -2 ^ 53, 2 ^ 63, 1e300, -1e300, 0.1, 1 / 3, 2 / 3, 1e-300, 5e-324,
            123456789.123456789, 1.7976931348623157e308, 2 ^ 53 + 2, 9.2e18, 9.3e18, 0.5, -0.5, 1e15 + 0.5 }
        for _, v in ipairs(nums) do
            local got = row1("SELECT $1::float8 AS v", v).v
            T.eq(got, v, "float8 round trip of " .. string.format("%.17g", v))
        end
        T.eq(row1("SELECT $1::text AS s", 2 ^ 53).s, "9007199254740992", "integral number formatting")
        T.eq(row1("SELECT $1::text AS s", 0.1).s, "0.1", "shortest decimal")
        T.eq(row1("SELECT $1::text AS s", -0.0).s, "0", "negative zero is sent as 0")
        T.eq(row1("SELECT $1::numeric AS n", 2 ^ 63).n, 2 ^ 63, "2^63 as numeric")
        local nr = row1("SELECT $1::float8 AS a, $2::float8 AS b, $3::float8 AS c", NaN, INF, -INF)
        T.ok(nr.a ~= nr.a and nr.b == INF and nr.c == -INF, "NaN/Infinity params " .. inspect(nr))
        T.eq(row1("SELECT $1::int8 AS v", "9007199254740993").v, "9007199254740993", "big int via string param")
        T.eq(row1("SELECT $1::int + $2::int AS v", "40", 2).v, 42, "string->int coercion by server")
        local long = string.rep("x", 10 * 1024 * 1024)
        T.eq(row1("SELECT length($1::text) AS n", long).n, #long, "10 MB parameter")

        T.raises("NUL byte", pgQuerySync, db, "SELECT $1::text", "a\0b")
        T.raises("unsupported parameter type 'function'", pgQuerySync, db, "SELECT $1", print)
        T.raises("unsupported parameter type 'thread'", pgQuerySync, db, "SELECT $1", coroutine.create(function() end))
        T.raises("unsupported parameter type 'userdata'", pgQuerySync, db, "SELECT $1", db)
        T.raises("bad query parameter %$2", pgQuerySync, db, "SELECT $1, $2", 1, print)
        T.raises("NUL byte", pgQuerySync, db, "SELECT 1\0")
        -- server-side parameter errors are returned
        local ok, err, state = pgQuerySync(db, "SELECT $1::int", "abc")
        T.eq({ ok, state }, { false, "22P02" }, "invalid int text")
        ok, err, state = pgQuerySync(db, "SELECT $1::int", 1, 2)
        T.eq({ ok, state }, { false, "08P01" }, "too many params for statement")
        T.match(err, "bind message supplies 2 parameters", "param count message")
        ok, err, state = pgQuerySync(db, "SELECT $1::numeric::int8", -1e19)
        T.eq({ ok, state }, { false, "22003" }, "out of range")
        ok, err, state = pgQuerySync(db, "SELECT $1::int8", -1e19) -- sent as "-1e+19"
        T.eq({ ok, state }, { false, "22P02" }, "exponent form is not valid int8 input")
    end },

    { "parameters: arrays", function()
        local strs = { "a,b", 'q"uote', "back\\slash", "{brace}", "x}y{z", "ünï©ødé 😀", "", "NULL", " sp ", "\\\"", "'" }
        T.eq(row1("SELECT $1::text[] AS a", strs).a, strs, "text[] round trip with special characters")
        T.eq(row1("SELECT $1::int[] AS a", { 1, 2, 3 }).a, { 1, 2, 3 }, "int[]")
        T.eq(row1("SELECT $1::int[] AS a", { { 1, 2 }, { 3, 4 } }).a, { { 1, 2 }, { 3, 4 } }, "int[][]")
        T.eq(row1("SELECT $1::int[] AS a", { [1] = 1, [3] = 3 }).a, { [1] = 1, [3] = 3 }, "holes become NULL")
        T.eq(row1("SELECT $1::int[] AS a", { 1, PG_NULL, 3 }).a, { [1] = 1, [3] = 3 }, "PG_NULL element")
        T.eq(row1("SELECT $1::int[] AS a, cardinality($1::int[]) AS n", {}).n, 0, "empty table -> empty array")
        T.eq(row1("SELECT $1::bool[] AS a", { true, false }).a, { true, false }, "bool[]")
        local fl = row1("SELECT $1::float8[] AS a", { 0.1, NaN, INF, -INF, 1e300 }).a
        T.ok(fl[1] == 0.1 and fl[2] ~= fl[2] and fl[3] == INF and fl[4] == -INF and fl[5] == 1e300, "float8[] " .. inspect(fl))
        local six = { { { { { { 1 } } } } } }
        T.eq(row1("SELECT $1::int[] AS a", six).a, six, "6 levels accepted")
        T.eq(row1("SELECT 3 = ANY($1::int[]) AS hit", { 1, 2, 3 }).hit, true, "ANY($1)")
        T.eq(row1("SELECT $1::bytea[] AS a", { pgBytea("\0\1"), pgBytea("") }).a, { "\0\1", "" }, "bytea[] via pgBytea")

        T.raises("must be arrays", pgQuerySync, db, "SELECT $1::int[]", { a = 1 })
        T.raises("must be arrays", pgQuerySync, db, "SELECT $1::int[]", { [0] = 1 })
        T.raises("must be arrays", pgQuerySync, db, "SELECT $1::int[]", { [1.5] = 1 })
        T.raises("must be arrays", pgQuerySync, db, "SELECT $1::int[]", { [-1] = 1 })
        T.raises("must be arrays", pgQuerySync, db, "SELECT $1::int[]", { [2 ^ 40] = 1 })
        T.raises("must be arrays", pgQuerySync, db, "SELECT $1::int[]", { [INF] = 1 })
        T.raises("must be arrays", pgQuerySync, db, "SELECT $1::int[]", { 1, 2, x = 3 })
        T.raises("nested too deeply", pgQuerySync, db, "SELECT $1::int[]", { { { { { { { 1 } } } } } } })
        local cyc = {}
        cyc[1] = cyc
        T.raises("nested too deeply", pgQuerySync, db, "SELECT $1::int[]", cyc)
        T.raises("NUL byte", pgQuerySync, db, "SELECT $1::text[]", { "ok", "a\0b" })
        T.raises("unsupported value of type 'function'", pgQuerySync, db, "SELECT $1::text[]", { print })
        local ok, err, state = pgQuerySync(db, "SELECT $1::int[]", { { 1, 2 }, { 3 } })
        T.eq({ ok, state }, { false, "22P02" }, "ragged array rejected by server")
    end },

    { "callbacks: argument shapes, affected rows, errors", function()
        local res = pack(T.query(db, "INSERT INTO " .. tbl .. " (k, v) VALUES ($1, 1), ($2, 2)", "a", "b"))
        T.eq(res.n, 3, "success passes 3 values")
        T.eq({ res[1], res[2], res[3] }, { {}, nil, 2 }, "insert: rows, nil, affected")
        T.eq(select(3, T.query(db, "UPDATE " .. tbl .. " SET v = v + 1 WHERE k IN ('a', 'b')")), 2, "update affected")
        T.eq(select(3, T.query(db, "DELETE FROM " .. tbl .. " WHERE k = 'b'")), 1, "delete affected")
        T.eq(select(3, T.query(db, "SELECT g FROM generate_series(1, 7) g")), 7, "select affected = row count")
        local rows = T.query(db, "INSERT INTO " .. tbl .. " (k) VALUES ('ret') RETURNING id, k")
        T.ok(rows and rows[1].k == "ret" and type(rows[1].id) == "number", "RETURNING")

        local errors = {
            { "SELECT * FROM nonexistent_tbl_xyz", "42P01", "does not exist" },
            { "SELEC 1", "42601", "syntax error" },
            { "SELECT 1/0", "22012", "division by zero" },
            { "INSERT INTO " .. tbl .. " (k) VALUES ('a')", "23505", "duplicate key" },
            { "INSERT INTO " .. tbl .. " (k, v) VALUES ('neg', -1)", "23514", "check constraint" },
            { "INSERT INTO " .. tbl .. "_fk VALUES (999999)", "23503", "foreign key" },
            { "SELECT nonexistent_col FROM (SELECT 1) s", "42703", "column" },
            { "DO $$BEGIN RAISE EXCEPTION 'custom' USING ERRCODE = 'P0001'; END$$", "P0001", "custom" },
        }
        for _, e in ipairs(errors) do
            local r = pack(T.query(db, e[1]))
            T.eq(r.n, 3, "failure passes 3 values for " .. e[2])
            T.eq({ r[1], r[3] }, { false, e[2] }, "sqlstate for " .. e[1])
            T.match(r[2], e[3], "message for " .. e[2])
        end
        -- deferred constraint fails at the implicit COMMIT (after the statement itself succeeded)
        local d = pack(T.query(db, "INSERT INTO " .. tbl .. "_def VALUES (1), (1)"))
        T.eq({ d[1], d[3] }, { false, "23505" }, "deferred unique violation at commit")

        -- callback errors are reported (level 1) and do not affect other queries
        T.ok(pgQuery(db, function() error("boom in callback") end, "SELECT 1"), "submit erroring callback")
        T.ok(pgQuery(db, function() error({}) end, "SELECT 1"), "submit callback with table error")
        local after = T.query(db, "SELECT 2 AS x")
        T.eq(after, { { x = 2 } }, "query after callback errors")
        T.expectDebug("error in pgsql callback: .*boom in callback", 1, 1)
        T.expectDebug("error in pgsql callback: %(error object is not a string%)", 1, 1)

        -- argument errors raise
        T.raises("bad argument #1", pgQuery, nil, print, "SELECT 1")
        T.raises("bad argument #1", pgQuery, {}, print, "SELECT 1")
        T.raises("bad argument #2", pgQuery, db, "SELECT 1")
        T.raises("bad argument #3", pgQuery, db, print, nil)
        T.raises("bad argument #2", pgExec, db)
        local numberSql = pack(T.query(db, 12345))
        T.eq({ numberSql[1], numberSql[3] }, { false, "42601" }, "number as SQL is converted to text")
    end },

    { "pgExec: success, failure warnings with call site, multi-statement", function()
        T.eq(pgExec(db, "UPDATE " .. tbl .. " SET v = 5 WHERE k = 'seed'"), true, "pgExec returns true")
        local line = debug.getinfo(1, "l").currentline + 1
        pgExec(db, "SELECT * FROM missing_table_for_exec")
        T.query(db, "SELECT 1") -- same connection, poolSize 1: the exec has completed before this returns
        T.sleep(20)
        T.expectDebug("pgExec failed: .*missing_table_for_exec.*%[42P01%] %(called at main/main%.lua:" .. line .. "%)", 1, 2)
        db:exec("SELECT 1/0")
        T.query(db, "SELECT 1")
        T.sleep(20)
        T.expectDebug("pgExec failed: .*division by zero %[22012%] %(called at main/main%.lua:%d+%)", 1, 2)
        pcall(pgExec, db, "SELECT 1/0") -- called from a C function: no call site
        T.query(db, "SELECT 1")
        T.sleep(20)
        T.expectDebug("pgExec failed: .*division by zero %[22012%]$", 1, 2)

        -- multi-statement with a failure in the middle: the whole string is one implicit transaction
        pgExec(db, "INSERT INTO " .. tbl .. " (k) VALUES ('ms1'); SELECT 1/0; INSERT INTO " .. tbl .. " (k) VALUES ('ms2');")
        local n = T.query(db, "SELECT count(*)::int AS n FROM " .. tbl .. " WHERE k LIKE 'ms%'")
        T.eq(n, { { n = 0 } }, "failed multi-statement rolled back")
        T.sleep(20)
        T.expectDebug("pgExec failed: .*division by zero", 1, 2)
        local ms = T.query(db, "SELECT 1 AS a; SELECT 2 AS b")
        T.eq(ms, { { b = 2 } }, "multi-statement pgQuery returns the last result")
        T.eq(T.query(db, "SELECT ';x' AS s"), { { s = ";x" } }, "semicolon inside a literal")
        T.eq(T.query(db, "SELECT $1::text || ';' AS s", "p"), { { s = "p;" } }, "semicolon with params")
        T.eq(T.query(db, "SELECT 1 AS a;  \n "), { { a = 1 } }, "trailing semicolon")
        T.eq(pack(T.query(db, "")).n, 3, "empty query")
        T.eq(T.query(db, "  -- only a comment"), {}, "comment-only query")
        T.eq(T.query(db, "DO $$BEGIN RAISE NOTICE 'notice ignored'; END$$"), {}, "notices are ignored")
        T.eq(T.query(db, "LISTEN harness_chan; NOTIFY harness_chan, 'x'; SELECT 1 AS a"), { { a = 1 } }, "LISTEN/NOTIFY drained")
        T.eq(T.query(db, "SELECT 2 AS b"), { { b = 2 } }, "after notify")
    end },

    { "COPY", function()
        local r = pack(T.query(db, "COPY " .. tbl .. " (k) FROM STDIN"))
        T.eq(r[1], false, "COPY FROM STDIN fails")
        T.match(r[2], "COPY", "COPY FROM STDIN message")
        T.eq(T.query(db, "SELECT 1 AS ok"), { { ok = 1 } }, "connection usable after COPY FROM STDIN")
        pgExec(db, "copy " .. tbl .. " (k) from stdin")
        T.query(db, "SELECT 1")
        T.sleep(20)
        T.expectDebug("pgExec failed: .*COPY", 1, 2)
        local out = pack(T.query(db, "/* leading comment */ COPY (SELECT g FROM generate_series(1, 1000) g) TO STDOUT"))
        T.eq({ out[1], out[3] }, { {}, 1000 }, "COPY TO STDOUT: no rows, affected = rows copied")
        T.eq(T.query(db, "SELECT 3 AS ok"), { { ok = 3 } }, "connection usable after COPY TO STDOUT")
        -- PostgreSQL allows nested block comments; COPY hidden behind one goes down the pipeline path
        local nested = pack(T.query(db, "/* a /* b */ c */ COPY (SELECT 1) TO STDOUT"))
        T.ok(nested[1] == false or T.deepEq(nested[1], {}), "COPY behind a nested comment is refused or runs as COPY")
        T.log("nested-comment COPY result: " .. inspect({ nested[2], nested[3] }))
        T.eq(T.query(db, "SELECT 4 AS ok"), { { ok = 4 } }, "connection usable after pipelined COPY")
    end },

    { "transactions: success, failure, rollback, validation", function()
        local res, err, affected = T.tx(db, {
            "INSERT INTO " .. tbl .. " (k, v) VALUES ('t1', 1)",
            { "INSERT INTO " .. tbl .. " (k, v) VALUES ($1, $2)", "t2", 2 },
            { "SELECT k, v FROM " .. tbl .. " WHERE k IN ($1, $2) ORDER BY k", "t1", "t2" },
            { "UPDATE " .. tbl .. " SET v = $2 WHERE k = $1", "t1", PG_NULL },
            { "SELECT $1::int IS NULL AS a, $2::text IS NULL AS b, $3::int AS c", nil, nil, 3 },
        })
        T.eq(res, { {}, {}, { { k = "t1", v = 1 }, { k = "t2", v = 2 } }, {}, { { a = true, b = true, c = 3 } } }, "transaction results")
        T.eq(err, nil, "no error")
        T.eq(affected, { 1, 1, 2, 1, 1 }, "affected per statement")

        local r = pack(T.tx(db, {
            "INSERT INTO " .. tbl .. " (k) VALUES ('rolled_back')",
            "INSERT INTO " .. tbl .. " (k) VALUES ('t1')",
            "INSERT INTO " .. tbl .. " (k) VALUES ('never')",
        }))
        T.eq(r.n, 4, "failure passes 4 values")
        T.eq({ r[1], r[3], r[4] }, { false, "23505", 2 }, "failed statement index")
        T.eq(T.query(db, "SELECT count(*)::int AS n FROM " .. tbl .. " WHERE k IN ('rolled_back', 'never')"), { { n = 0 } }, "rolled back")
        r = pack(T.tx(db, { "SELECT 1/0", "SELECT 1" }))
        T.eq({ r[1], r[3], r[4] }, { false, "22012", 1 }, "first statement fails")
        r = pack(T.tx(db, { "INSERT INTO " .. tbl .. "_def VALUES (7)", "INSERT INTO " .. tbl .. "_def VALUES (7)" }))
        T.eq({ r[1], r[3] }, { false, "23505" }, "deferred constraint fails at commit")
        T.log("deferred failure index: " .. tostring(r[4]))
        T.eq(T.query(db, "SELECT count(*)::int AS n FROM " .. tbl .. "_def"), { { n = 0 } }, "deferred failure rolled back")
        r = pack(T.tx(db, { "INSERT INTO " .. tbl .. " (k) VALUES ('m1'); INSERT INTO " .. tbl .. " (k) VALUES ('m2')" }))
        T.eq({ r[1], r[3] }, { false, "42601" }, "multi-command statement in a transaction")

        for _, ctl in ipairs({ "BEGIN", "begin", "  -- c\n COMMIT", "/* x */ ROLLBACK", "START TRANSACTION", "END", "ABORT",
            "SAVEPOINT s", "RELEASE s", "PREPARE TRANSACTION 'x'", "COPY x FROM STDIN" }) do
            T.raises("not allowed", pgTransaction, db, { "SELECT 1", ctl }, print)
        end
        T.raises("statements table is empty", pgTransaction, db, {}, print)
        T.raises("must be a string or", pgTransaction, db, { 42 }, print)
        T.raises("must be a string or", pgTransaction, db, { { 42 } }, print)
        T.raises("expected {sql, param1", pgTransaction, db, { { "SELECT 1", x = 1 } }, print)
        T.raises("expected {sql, param1", pgTransaction, db, { { "SELECT 1", [70000] = 1 } }, print)
        T.raises("expected {sql, param1", pgTransaction, db, { { "SELECT 1", [1e300] = 1 } }, print)  -- double -> size_t cast
        T.raises("expected {sql, param1", pgTransaction, db, { { "SELECT 1", [INF] = 1 } }, print)
        T.raises("NUL byte", pgTransaction, db, { "SELECT 1\0" }, print)
        T.raises("bad parameter %$1", pgTransaction, db, { { "SELECT $1", print } }, print)
        T.raises("bad argument #2", pgTransaction, db, "SELECT 1", print)
        T.raises("bad argument #3", pgTransaction, db, { "SELECT 1" })

        local big = {}
        for i = 1, 1000 do big[i] = { "SELECT $1::int AS i", i } end
        local bres = T.tx(db, big)
        T.eq(bres and #bres, 1000, "1000-statement transaction")
        T.eq(bres and bres[1000][1].i, 1000, "last result")

        -- Await and sync forms + methods
        local ares = pack(pgTransactionAwait(db, { "SELECT 1 AS a", { "SELECT $1::int AS b", 2 } }))
        T.eq({ ares[1], ares[2], ares[3] }, { { { { a = 1 } }, { { b = 2 } } }, nil, { 1, 1 } }, "pgTransactionAwait")
        local sres = pack(pgTransactionSync(db, { "SELECT 1/0" }))
        T.eq({ sres[1], sres[3], sres[4] }, { false, "22012", 1 }, "pgTransactionSync failure")
        T.eq(db:transactionSync({ "SELECT 5 AS x" }), { { { x = 5 } } }, "db:transactionSync")
        T.eq(db:transactionAwait({ "SELECT 6 AS x" }), { { { x = 6 } } }, "db:transactionAwait")
        T.eq(T.wait(function(w) db:transaction({ "SELECT 7 AS x" }, w) end), { { { x = 7 } } }, "db:transaction")
    end },

    { "transaction control the keyword check misses (nested comment, empty statement)", function()
        -- PostgreSQL nests /* */ comments and drops empty statements, so both of these are a
        -- COMMIT. pgTransaction must either reject them or stay atomic.
        for _, case in ipairs({ { "nested_commit", "/* a /* b */ c */ COMMIT" }, { "semi_commit", "; COMMIT" } }) do
            local key, ctl = case[1], case[2]
            local outcome = pack(T.wait(function(wake)
                local ok, err = pcall(pgTransaction, db, {
                    "INSERT INTO " .. tbl .. " (k) VALUES ('" .. key .. "')", ctl, "SELECT 1/0",
                }, function(...) wake("completed", ...) end)
                if not ok then wake("raised", err) end
            end))
            local persisted = T.query(db, "SELECT count(*)::int AS n FROM " .. tbl .. " WHERE k = $1", key)
            T.log(("%q inside pgTransaction: %s, persisted=%s"):format(ctl, inspect({ outcome[1], outcome[2], outcome[3], outcome[4], outcome[5] }), inspect(persisted)))
            if outcome[1] == "raised" then
                T.match(outcome[2], "not allowed", "rejected: " .. ctl)
            else
                T.eq(persisted, { { n = 0 } }, "atomicity holds with " .. ctl)
            end
        end
    end },

    { "transaction blocks must not leak out of a query (session poisoning / lost writes)", function()
        local c = assert(pgConnect(CONNINFO, { applicationName = "func-poison" }))
        -- a migration-style script that fails before its COMMIT
        pgExec(c, "BEGIN; SELECT 1/0; COMMIT;")
        local r = pack(T.query(c, "SELECT 1 AS x"))
        T.eq({ r[1], r[2] }, { { { x = 1 } }, nil }, "next query on the same connection works (no 25P02)")
        -- a script that leaves the block open: rolled back, and its job must not report success
        local open = pack(T.query(c, "BEGIN; INSERT INTO " .. tbl .. " (k) VALUES ('left_open')"))
        local leftOpen = T.query(T.admin(), "SELECT count(*)::int AS n FROM " .. tbl .. " WHERE k = 'left_open'")
        T.log("script leaving BEGIN open: " .. inspect({ open[1], open[2], open[3] }) .. ", rows: " .. inspect(leftOpen))
        T.ok(open[1] == false or T.deepEq(leftOpen, { { n = 1 } }), "either reported as failed or durable")
        T.eq(T.query(c, "SELECT 2 AS x"), { { x = 2 } }, "session usable afterwards")
        pgClose(c)

        -- standalone BEGIN, and BEGIN the keyword check may miss, followed by writes in the
        -- same frame (same pipeline batch): acknowledged writes must be durable
        local variants = {
            { "plain", "BEGIN" },
            { "nested", "/* a /* b */ c */ BEGIN" },
            { "semicolon", "; BEGIN" },
        }
        for _, v in ipairs(variants) do
            local name, sql = v[1], v[2]
            local key = "after_begin_" .. name
            local cc = assert(pgConnect(CONNINFO, { applicationName = "func-dangling" }))
            local okExec, execErr = pcall(pgExec, cc, sql)
            local acks = {}
            for i = 1, 3 do
                pgQuery(cc, function(rows, err, st) acks[i] = rows and "ok" or tostring(st) end,
                    "INSERT INTO " .. tbl .. " (k) VALUES ($1)", key .. "_" .. i)
            end
            T.waitFor(function() return acks[1] and acks[2] and acks[3] end, 5000 * SLOW, "acks for " .. name)
            pgClose(cc)
            T.waitBackends("func-dangling", 0, 3000 * SLOW, "closed")
            local durable = pgQuerySync(T.admin(), "SELECT count(*)::int AS n FROM " .. tbl .. " WHERE k LIKE $1", key .. "%")
            local okAcks = 0
            for i = 1, 3 do if acks[i] == "ok" then okAcks = okAcks + 1 end end
            T.log(("%-9s %-28q pgExec: %s; inserts acknowledged %d/3, durable %s"):format(name, sql,
                okExec and "accepted" or ("raised: " .. tostring(execErr)), okAcks, inspect(durable)))
            T.eq(durable and durable[1].n, okAcks, "every acknowledged insert is durable (" .. name .. ")")
        end
        T.sleep(20)
        T.takeDebug("pgExec failed", 2)
    end },

    { "methods, pgStats, pgQuoteIdent, pgClose", function()
        local c = assert(pgConnect(CONNINFO, { applicationName = "func-methods" }))
        T.eq(T.wait(function(w) c:query(w, "SELECT 1 AS a") end), { { a = 1 } }, "db:query")
        T.eq(c:querySync("SELECT 2 AS a"), { { a = 2 } }, "db:querySync")
        T.eq(c:queryAwait("SELECT 3 AS a"), { { a = 3 } }, "db:queryAwait")
        T.eq(c:exec("SELECT 4"), true, "db:exec")
        c:querySync("SELECT 1/0")
        c:querySync("SELECT nope")
        local s = c:stats()
        T.eq({ s.poolSize, s.connected, s.queued, s.inFlight, s.submitted, s.succeeded, s.failed, s.reconnects },
            { 1, 1, 0, 0, 6, 4, 2, 0 }, "stats counters " .. inspect(s))
        T.ok(s.roundTrips >= 1 and s.roundTrips <= 6, "roundTrips")
        T.ok(type(s.avgLatencyMs) == "number" and s.avgLatencyMs >= 0, "avgLatencyMs")
        T.eq(pgStats(c), c:stats(), "pgStats == db:stats")

        T.eq(pgQuoteIdent('my"table'), '"my""table"', "pgQuoteIdent")
        T.eq(pgQuoteIdent(""), '""', "pgQuoteIdent empty")
        T.raises("NUL byte", pgQuoteIdent, "a\0b")
        local weird = 'we"ird ' .. T.uniq("tbl")
        T.ok(pgQuerySync(c, "CREATE TEMP TABLE " .. pgQuoteIdent(weird) .. " (x int)"), "quoted identifier usable")

        T.eq(c:close(), true, "close")
        T.eq(pgClose(c), false, "second close")
        T.match(tostring(c), "%(closed%)", "tostring after close")
        T.eq(pack(pgQuery(c, print, "SELECT 1")), { n = 2, false, "connection is closed" }, "pgQuery after close")
        T.eq(pack(pgExec(c, "SELECT 1")), { n = 2, false, "connection is closed" }, "pgExec after close")
        T.eq(pack(pgQuerySync(c, "SELECT 1")), { n = 2, false, "connection is closed" }, "pgQuerySync after close")
        T.eq(pack(pgQueryAwait(c, "SELECT 1")), { n = 2, false, "connection is closed" }, "pgQueryAwait after close (no yield)")
        T.eq(pack(pgTransaction(c, { "SELECT 1" }, print)), { n = 2, false, "connection is closed" }, "pgTransaction after close")
        T.eq(pack(pgStats(c)), { n = 2, false, "connection is closed" }, "pgStats after close")
        T.waitBackends("func-methods", 0, 3000 * SLOW, "closed connection left the server")
    end },

    { "cleanup", function()
        pgQuerySync(db, ("DROP TABLE %s_fk; DROP TABLE %s_def; DROP TABLE %s"):format(tbl, tbl, tbl))
        for _, c in ipairs({ db, dbStr, dbNum, dbEsc }) do pgClose(c) end
    end },
})

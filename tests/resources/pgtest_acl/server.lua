-- This resource is denied function.pgConnect in acl.xml.
addEventHandler("onResourceStart", resourceRoot, function()
    local db = pgConnect("host=postgres user=mta password=mta dbname=mta")
    outputDebugString("ACLRESULT " .. tostring(db))
end)

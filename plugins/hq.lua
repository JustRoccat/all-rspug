return {
    on_search_query = function(query)
    if not query:lower():match("high quality") and not query:lower():match("audio") then
        local new_query = query .. " high quality audio"
        return new_query
        end
        return query
        end
}

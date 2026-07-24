-- Run after migrations as postgres. Any returned row is a release blocker.
select 'anon_schema_usage' as failure
where has_schema_privilege('anon', 'tono_private', 'USAGE')
union all
select 'authenticated_schema_usage'
where has_schema_privilege('authenticated', 'tono_private', 'USAGE')
union all
select 'anon_identity_links_select'
where has_table_privilege('anon', 'tono_private.identity_links', 'SELECT')
union all
select 'authenticated_identity_links_select'
where has_table_privilege('authenticated', 'tono_private.identity_links', 'SELECT')
union all
select 'public_identity_links_select'
where has_table_privilege('public', 'tono_private.identity_links', 'SELECT');

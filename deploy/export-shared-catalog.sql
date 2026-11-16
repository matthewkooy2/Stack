\set ON_ERROR_STOP on
BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ;

-- Jac serves inventory from its internal guest root. Export only direct catalog
-- nodes and their guest-to-node edges, never account roots or identity records.
COPY (
    WITH guest AS (
        SELECT (users.doc->>'root_id')::uuid AS id
        FROM identity_lookups lookup JOIN identity_users users USING (user_id)
        WHERE lookup.value_normalized='__guest__'
    ), catalog AS (
        SELECT node.*
        FROM anchors node JOIN guest ON guest.id=node.root_id
        WHERE node.kind='NodeAnchor'
          AND node.arch_module ~ '^_jac_app_[0-9a-f]{16}\.core\.catalog$'
          AND (
              node.arch_type IN ('CatalogJob','JobAlias','JobSource','CatalogTitles','CatalogMatchGroup')
              OR (node.arch_type='SweepRun' AND node.props->'archetype'->>'status' IN ('done','failed'))
          )
    ), transfer AS (
        SELECT * FROM catalog
        UNION ALL
        SELECT edge.*
        FROM anchors edge JOIN catalog node ON edge.dst=node.id
        WHERE edge.root_id=node.root_id AND edge.src=node.root_id
          AND edge.kind='EdgeAnchor' AND edge.arch_type='GenericEdge'
          AND edge.arch_module='jaclang.runtime.archetype'
    )
    SELECT id,kind,arch_type,arch_module,fingerprint,root_id,src,dst,undirected,props,format_version,version
    FROM transfer
) TO STDOUT WITH (FORMAT csv, NULL '\N');

COMMIT;

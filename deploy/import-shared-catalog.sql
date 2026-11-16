\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout='5s';
LOCK TABLE anchors IN SHARE ROW EXCLUSIVE MODE;

-- Input is the CSV emitted by export-shared-catalog.sql. Use \copy's process
-- stdin so the operator can decompress the snapshot without a second file.
CREATE TEMP TABLE shared_catalog_seed ON COMMIT DROP AS
SELECT id,kind,arch_type,arch_module,fingerprint,root_id,src,dst,undirected,props,format_version,version
FROM anchors WITH NO DATA;
\copy shared_catalog_seed FROM pstdin WITH (FORMAT csv, NULL '\N')
CREATE UNIQUE INDEX ON shared_catalog_seed (id);
CREATE INDEX ON shared_catalog_seed (dst) WHERE kind='EdgeAnchor';

CREATE TEMP TABLE shared_catalog_destination ON COMMIT DROP AS
SELECT (users.doc->>'root_id')::uuid AS root_id, :'catalog_module'::text AS catalog_module
FROM identity_lookups lookup JOIN identity_users users USING (user_id)
WHERE lookup.value_normalized='__guest__';

DO $$
BEGIN
    IF (SELECT count(*) FROM shared_catalog_destination destination
        JOIN anchors root ON root.id=destination.root_id AND root.arch_type='Root'
        WHERE destination.catalog_module ~ '^_jac_app_[0-9a-f]{16}\.core\.catalog$') <> 1 THEN
        RAISE EXCEPTION 'Initialize the target Stack API and provide its catalog module before importing';
    END IF;
    IF EXISTS (SELECT FROM anchors WHERE arch_type IN ('CatalogJob','JobAlias','JobSource','CatalogTitles','CatalogMatchGroup','SweepRun')) THEN
        RAISE EXCEPTION 'Shared catalog seed requires a fresh target catalog';
    END IF;
    IF NOT EXISTS (SELECT FROM shared_catalog_seed WHERE kind='NodeAnchor' AND arch_type='CatalogJob')
       OR (SELECT count(DISTINCT root_id) FROM shared_catalog_seed) <> 1 THEN
        RAISE EXCEPTION 'Expected a nonempty catalog with one source root';
    END IF;
    IF EXISTS (
        SELECT FROM shared_catalog_seed seed WHERE seed.root_id IS NULL OR seed.props->>'root' IS DISTINCT FROM seed.root_id::text
          OR (seed.kind IS DISTINCT FROM 'NodeAnchor' AND seed.kind IS DISTINCT FROM 'EdgeAnchor')
          OR (seed.kind='NodeAnchor' AND (
              seed.arch_type IS NULL OR seed.arch_type NOT IN ('CatalogJob','JobAlias','JobSource','CatalogTitles','CatalogMatchGroup','SweepRun')
              OR seed.arch_module !~ '^_jac_app_[0-9a-f]{16}\.core\.catalog$'
              OR seed.src IS NOT NULL OR seed.dst IS NOT NULL
              OR (seed.props->'access' IS DISTINCT FROM 'null'::jsonb AND seed.props->'access' IS DISTINCT FROM
                  '{"all":0,"roots":{"anchors":{}},"groups":{"anchors":{}}}'::jsonb)
              OR (SELECT count(*) FROM shared_catalog_seed edge WHERE edge.kind='EdgeAnchor' AND edge.dst=seed.id) <> 1
          ))
          OR (seed.kind='EdgeAnchor' AND (
              seed.arch_type IS DISTINCT FROM 'GenericEdge' OR seed.arch_module IS DISTINCT FROM 'jaclang.runtime.archetype'
              OR seed.src IS DISTINCT FROM seed.root_id OR seed.props->>'source' IS DISTINCT FROM seed.src::text
              OR seed.props->>'target' IS DISTINCT FROM seed.dst::text
              OR seed.props->'access' IS DISTINCT FROM 'null'::jsonb
              OR NOT EXISTS (SELECT FROM shared_catalog_seed node WHERE node.kind='NodeAnchor' AND node.id=seed.dst)
          ))
    ) THEN
        RAISE EXCEPTION 'Unexpected rows, links or access grants outside the shared catalog';
    END IF;
END $$;

INSERT INTO anchors(id,kind,arch_type,arch_module,fingerprint,root_id,src,dst,undirected,props,format_version,version)
SELECT seed.id,seed.kind,seed.arch_type,
       CASE WHEN seed.kind='NodeAnchor' THEN destination.catalog_module ELSE seed.arch_module END,
       seed.fingerprint,destination.root_id,
       CASE WHEN seed.kind='EdgeAnchor' THEN destination.root_id ELSE seed.src END,seed.dst,seed.undirected,
       CASE WHEN seed.kind='NodeAnchor' THEN
           jsonb_set(jsonb_set(seed.props,'{root}',to_jsonb(destination.root_id::text)),
                     '{archetype,__module__}',to_jsonb(destination.catalog_module))
       ELSE seed.props || jsonb_build_object('root',destination.root_id::text,'source',destination.root_id::text) END,
       seed.format_version,seed.version
FROM shared_catalog_seed seed CROSS JOIN shared_catalog_destination destination
ORDER BY seed.kind DESC;

SELECT (SELECT count(*) FROM shared_catalog_seed WHERE arch_type='CatalogJob') AS listings,
       (SELECT count(*) FROM shared_catalog_seed WHERE arch_type='CatalogJob' AND props->'archetype'->'active'='true') AS marked_active,
       (SELECT count(*) FROM shared_catalog_seed WHERE arch_type='CatalogJob' AND props->'archetype'->'active'='false') AS inactive;
COMMIT;

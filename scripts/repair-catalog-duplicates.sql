-- Run with all application writers stopped and a verified database backup.
-- Keep one record per shared-root job key, preserving its source history.
\set ON_ERROR_STOP on
BEGIN;
LOCK TABLE anchors IN ACCESS EXCLUSIVE MODE;

CREATE TEMP TABLE duplicate_catalog_jobs ON COMMIT DROP AS
SELECT id, root_id, props, props->'archetype' AS job,
       first_value(id) OVER w AS keep_id,
       min((props->'archetype'->>'discovered_at')::double precision) OVER g AS first_discovered,
       count(*) OVER g AS copies
FROM anchors
WHERE arch_type='CatalogJob'
WINDOW g AS (PARTITION BY root_id,props->'archetype'->>'key'),
       w AS (PARTITION BY root_id,props->'archetype'->>'key'
             ORDER BY (props->'archetype'->>'checked_at')::double precision DESC,id);
DELETE FROM duplicate_catalog_jobs WHERE copies=1;

DO $$
BEGIN
  IF EXISTS (SELECT FROM anchors WHERE arch_type='CatalogJob'
             AND (root_id IS NULL OR coalesce(props->'archetype'->>'key','')='')) THEN
    RAISE EXCEPTION 'Catalog contains missing roots or job keys';
  END IF;
  IF EXISTS (SELECT FROM duplicate_catalog_jobs WHERE jsonb_typeof(job->'observations') IS DISTINCT FROM 'object') THEN
    RAISE EXCEPTION 'Duplicate has invalid source observations';
  END IF;
  IF EXISTS (SELECT FROM duplicate_catalog_jobs GROUP BY keep_id HAVING count(DISTINCT job->>'identity')>1 OR count(DISTINCT props->'access')>1) THEN
    RAISE EXCEPTION 'Duplicate identity or access differs; manual review required';
  END IF;
  IF EXISTS (SELECT FROM duplicate_catalog_jobs d JOIN anchors e ON (e.src=d.id OR e.dst=d.id)
             WHERE d.id<>d.keep_id AND NOT (e.kind='EdgeAnchor' AND e.arch_type='GenericEdge' AND e.src=d.root_id AND e.dst=d.id)) THEN
    RAISE EXCEPTION 'Duplicate has unexpected graph links';
  END IF;
  IF EXISTS (SELECT FROM duplicate_catalog_jobs d WHERE d.id<>d.keep_id AND
             (SELECT count(*) FROM anchors e WHERE e.kind='EdgeAnchor' AND e.arch_type='GenericEdge' AND e.src=d.root_id AND e.dst=d.id)<>1) THEN
    RAISE EXCEPTION 'Duplicate does not have exactly one catalog link';
  END IF;
END $$;

CREATE TEMP TABLE merged_catalog_observations ON COMMIT DROP AS
SELECT keep_id, jsonb_object_agg(source_id, observation) AS observations
FROM (
  SELECT DISTINCT ON (d.keep_id, o.key) d.keep_id,o.key AS source_id,o.value AS observation
  FROM duplicate_catalog_jobs d CROSS JOIN LATERAL jsonb_each(d.job->'observations') o
  ORDER BY d.keep_id,o.key,coalesce((o.value->>'last_seen')::double precision,0) DESC,
           (d.id=d.keep_id) DESC,d.id
) chosen GROUP BY keep_id;

UPDATE anchors a SET
  props=jsonb_set(jsonb_set(a.props,'{archetype,discovered_at}',to_jsonb(d.first_discovered)),
                  '{archetype,observations}',coalesce(m.observations,'{}'::jsonb)),
  version=a.version+1,updated_at=now()
FROM duplicate_catalog_jobs d LEFT JOIN merged_catalog_observations m ON m.keep_id=d.keep_id
WHERE a.id=d.id AND d.id=d.keep_id;

DELETE FROM anchors e USING duplicate_catalog_jobs d
WHERE d.id<>d.keep_id AND e.kind='EdgeAnchor' AND e.arch_type='GenericEdge'
  AND e.src=d.root_id AND e.dst=d.id;
DELETE FROM anchors a USING duplicate_catalog_jobs d WHERE d.id<>d.keep_id AND a.id=d.id;

-- An existing compact projection may still describe the discarded copy.
UPDATE anchors SET props=jsonb_set(props,'{archetype,complete}','false'::jsonb),
  version=version+1,updated_at=now()
WHERE arch_type='CatalogTitles' AND props->'archetype'->'complete'='true'::jsonb;

CREATE UNIQUE INDEX IF NOT EXISTS stack_catalog_job_root_key_unique
ON anchors (root_id, ((props->'archetype'->>'key')))
WHERE arch_type='CatalogJob';

DO $$
BEGIN
  IF EXISTS (SELECT FROM anchors WHERE arch_type='CatalogJob' GROUP BY root_id,props->'archetype'->>'key' HAVING count(*)>1) THEN
    RAISE EXCEPTION 'Duplicate job keys remain';
  END IF;
END $$;
SELECT json_build_object('duplicate_keys_repaired',count(*) FILTER (WHERE id=keep_id),
                         'duplicate_records_removed',count(*) FILTER (WHERE id<>keep_id)) AS repair_summary
FROM duplicate_catalog_jobs;
COMMIT;

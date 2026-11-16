\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout='5s';
LOCK TABLE anchors IN SHARE ROW EXCLUSIVE MODE;

-- On a restored copy only, bind typed anchors to the absolute path of the
-- new main.jac entry. The runtime hashes that path into the module namespace.
CREATE TEMP TABLE stack_namespace_move ON COMMIT DROP AS
SELECT :'source_namespace'::text AS source, :'destination_namespace'::text AS destination;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM stack_namespace_move
        WHERE source ~ '^_jac_app_[0-9a-f]{16}$'
          AND destination ~ '^_jac_app_[0-9a-f]{16}$' AND source<>destination
    ) THEN
        RAISE EXCEPTION 'Expected two different Stack application namespaces';
    END IF;
END $$;

UPDATE anchors a
SET arch_module=CASE WHEN starts_with(a.arch_module, move.source || '.')
                  THEN move.destination || substr(a.arch_module,length(move.source)+1)
                  ELSE a.arch_module END,
    props=replace(a.props::text,
                  '"__module__": "' || move.source || '.',
                  '"__module__": "' || move.destination || '.')::jsonb
FROM stack_namespace_move move
WHERE starts_with(a.arch_module, move.source || '.')
   OR strpos(a.props::text, '"__module__": "' || move.source || '.')>0;

COMMIT;

-- What the Supabase PLATFORM provides that schema.sql assumes, for building an empty database
-- outside Supabase (scripts/schema_bootstrap.sh). The supabase/postgres image ships auth.users,
-- auth.uid(), the roles, and the extensions, but the storage tables and helpers are created by
-- the Storage API service, which is not part of the image, and pg_net / pg_cron are available
-- but not enabled. The definitions below follow storage-api's own migrations closely enough
-- for every policy and function in schema.sql. Never run this against production.
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE TABLE IF NOT EXISTS storage.buckets (
    id                 TEXT PRIMARY KEY,
    name               TEXT NOT NULL UNIQUE,
    owner              UUID,
    created_at         TIMESTAMPTZ DEFAULT NOW(),
    updated_at         TIMESTAMPTZ DEFAULT NOW(),
    public             BOOLEAN DEFAULT FALSE,
    avif_autodetection BOOLEAN DEFAULT FALSE,
    file_size_limit    BIGINT,
    allowed_mime_types TEXT[],
    owner_id           TEXT
);
CREATE TABLE IF NOT EXISTS storage.objects (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id        TEXT REFERENCES storage.buckets(id),
    name             TEXT,
    owner            UUID,
    created_at       TIMESTAMPTZ DEFAULT NOW(),
    updated_at       TIMESTAMPTZ DEFAULT NOW(),
    last_accessed_at TIMESTAMPTZ DEFAULT NOW(),
    metadata         JSONB,
    path_tokens      TEXT[] GENERATED ALWAYS AS (string_to_array(name, '/')) STORED,
    version          TEXT,
    owner_id         TEXT,
    user_metadata    JSONB
);
CREATE UNIQUE INDEX IF NOT EXISTS bucketid_objname ON storage.objects (bucket_id, name);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
GRANT ALL ON storage.objects, storage.buckets TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION storage.foldername(name TEXT)
RETURNS TEXT[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE _parts TEXT[];
BEGIN
    SELECT string_to_array(name, '/') INTO _parts;
    RETURN _parts[1:array_length(_parts, 1) - 1];
END;
$$;
CREATE OR REPLACE FUNCTION storage.filename(name TEXT)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE _parts TEXT[];
BEGIN
    SELECT string_to_array(name, '/') INTO _parts;
    RETURN _parts[array_length(_parts, 1)];
END;
$$;
CREATE OR REPLACE FUNCTION storage.extension(name TEXT)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE _parts TEXT[]; _filename TEXT;
BEGIN
    SELECT string_to_array(name, '/') INTO _parts;
    SELECT _parts[array_length(_parts, 1)] INTO _filename;
    RETURN reverse(split_part(reverse(_filename), '.', 1));
END;
$$;

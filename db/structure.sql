SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: active_storage_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying NOT NULL,
    record_type character varying NOT NULL,
    record_id uuid NOT NULL,
    blob_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_blobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key character varying NOT NULL,
    filename character varying NOT NULL,
    content_type character varying,
    metadata text,
    service_name character varying NOT NULL,
    byte_size bigint NOT NULL,
    checksum character varying,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_variant_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_variant_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    blob_id uuid NOT NULL,
    variation_digest character varying NOT NULL
);


--
-- Name: ai_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    provider character varying NOT NULL,
    api_key text,
    base_url character varying,
    model character varying,
    enabled boolean DEFAULT true NOT NULL,
    last_ok_at timestamp(6) without time zone,
    last_error character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_calls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_calls (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid,
    automation_id uuid,
    source character varying NOT NULL,
    provider character varying NOT NULL,
    model character varying,
    input_tokens integer DEFAULT 0 NOT NULL,
    output_tokens integer DEFAULT 0 NOT NULL,
    cost numeric(12,6) DEFAULT 0.0 NOT NULL,
    status character varying NOT NULL,
    error character varying,
    duration_ms integer,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_plan_features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_plan_features (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    feature character varying NOT NULL,
    plan character varying NOT NULL,
    tier character varying,
    "limit" integer,
    available boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_tier_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_tier_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tier character varying NOT NULL,
    provider character varying NOT NULL,
    model character varying NOT NULL,
    effort character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_usages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_usages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    feature character varying NOT NULL,
    period date NOT NULL,
    count integer DEFAULT 0 NOT NULL,
    input_tokens integer DEFAULT 0 NOT NULL,
    output_tokens integer DEFAULT 0 NOT NULL,
    model character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: alert_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.alert_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    point_id uuid NOT NULL,
    name character varying NOT NULL,
    operator character varying DEFAULT 'eq'::character varying NOT NULL,
    value jsonb,
    for_s integer DEFAULT 0 NOT NULL,
    severity character varying DEFAULT 'warning'::character varying NOT NULL,
    escalation jsonb DEFAULT '[]'::jsonb NOT NULL,
    repeat_s integer,
    auto_resolve boolean DEFAULT true NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: alerts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.alerts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    alert_rule_id uuid NOT NULL,
    point_id uuid NOT NULL,
    level integer DEFAULT 0 NOT NULL,
    opened_at timestamp(6) without time zone NOT NULL,
    acked_by_id uuid,
    acked_at timestamp(6) without time zone,
    resolved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: api_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    access_token_digest character varying NOT NULL,
    refresh_token_digest character varying NOT NULL,
    previous_refresh_token_digest character varying,
    access_expires_at timestamp(6) without time zone NOT NULL,
    refresh_expires_at timestamp(6) without time zone NOT NULL,
    device_name character varying,
    last_used_at timestamp(6) without time zone,
    revoked_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    site_id uuid,
    client character varying,
    redirect_uri character varying
);


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: areas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.areas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    parent_id uuid,
    name character varying NOT NULL,
    kind character varying DEFAULT 'room'::character varying NOT NULL,
    icon character varying,
    background character varying,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid,
    user_id uuid,
    action character varying NOT NULL,
    auditable_type character varying NOT NULL,
    auditable_id uuid,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: automation_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.automation_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    automation_id uuid NOT NULL,
    site_id uuid NOT NULL,
    cause_run_id uuid,
    version integer,
    trigger jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying DEFAULT 'running'::character varying NOT NULL,
    dry_run boolean DEFAULT false NOT NULL,
    depth integer DEFAULT 0 NOT NULL,
    steps jsonb DEFAULT '[]'::jsonb NOT NULL,
    state jsonb DEFAULT '{}'::jsonb NOT NULL,
    error character varying,
    started_at timestamp(6) without time zone NOT NULL,
    finished_at timestamp(6) without time zone,
    resume_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    shadow boolean DEFAULT false NOT NULL
);


--
-- Name: automation_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.automation_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    automation_id uuid NOT NULL,
    author_id uuid,
    version integer NOT NULL,
    definition jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: automations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.automations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    area_id uuid,
    name character varying NOT NULL,
    description text,
    enabled boolean DEFAULT false NOT NULL,
    mode character varying DEFAULT 'single'::character varying NOT NULL,
    max_runs integer DEFAULT 10 NOT NULL,
    definition jsonb DEFAULT '{}'::jsonb NOT NULL,
    draft jsonb,
    version integer DEFAULT 0 NOT NULL,
    webhook_token character varying,
    last_run_at timestamp(6) without time zone,
    last_status character varying,
    last_error character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    kind character varying DEFAULT 'automation'::character varying NOT NULL,
    fields jsonb DEFAULT '[]'::jsonb NOT NULL,
    icon character varying,
    blueprint_id uuid,
    blueprint_inputs jsonb,
    blueprint_version integer,
    shadow boolean DEFAULT false NOT NULL
);


--
-- Name: blueprints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.blueprints (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    name character varying NOT NULL,
    description text,
    domain character varying DEFAULT 'automation'::character varying NOT NULL,
    mode character varying DEFAULT 'single'::character varying NOT NULL,
    inputs jsonb DEFAULT '[]'::jsonb NOT NULL,
    definition jsonb DEFAULT '{}'::jsonb NOT NULL,
    source character varying DEFAULT 'manual'::character varying NOT NULL,
    source_url character varying,
    unsupported jsonb DEFAULT '[]'::jsonb NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: commands; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commands (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    point_id uuid NOT NULL,
    user_id uuid,
    command character varying NOT NULL,
    value jsonb,
    source character varying DEFAULT 'api'::character varying NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    error character varying,
    client_uuid uuid,
    sent_at timestamp(6) without time zone,
    confirmed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    origin_point_id uuid,
    automation_run_id uuid
);


--
-- Name: dashboard_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dashboard_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    dashboard_id uuid NOT NULL,
    author_id uuid,
    version integer NOT NULL,
    definition jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: dashboards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dashboards (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    name character varying NOT NULL,
    kind character varying DEFAULT 'custom'::character varying NOT NULL,
    auto boolean DEFAULT false NOT NULL,
    site_default boolean DEFAULT false NOT NULL,
    definition jsonb DEFAULT '{}'::jsonb NOT NULL,
    draft jsonb,
    schema_version integer DEFAULT 1 NOT NULL,
    version integer DEFAULT 0 NOT NULL,
    roles character varying[] DEFAULT '{}'::character varying[] NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    icon character varying,
    sidebar boolean DEFAULT false NOT NULL
);


--
-- Name: dataset_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dataset_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    dataset_id uuid NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    automation_run_id uuid,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: datasets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.datasets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    name character varying NOT NULL,
    key character varying NOT NULL,
    fields jsonb DEFAULT '[]'::jsonb NOT NULL,
    retention_days integer,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: device_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    token character varying NOT NULL,
    platform character varying DEFAULT 'android'::character varying NOT NULL,
    last_seen_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.devices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    area_id uuid,
    driver character varying DEFAULT 'virtual'::character varying NOT NULL,
    name character varying NOT NULL,
    manufacturer character varying,
    model character varying,
    serial character varying,
    external_id character varying,
    address jsonb DEFAULT '{}'::jsonb NOT NULL,
    firmware character varying,
    status character varying DEFAULT 'online'::character varying NOT NULL,
    last_seen_at timestamp(6) without time zone,
    battery_point_id uuid,
    disabled boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    credential text,
    listen boolean DEFAULT false NOT NULL,
    integration_id uuid,
    poll_s integer DEFAULT 1800,
    polled_at timestamp(6) without time zone,
    removed_at timestamp(6) without time zone,
    last_error character varying,
    discovered_at timestamp(6) without time zone
);


--
-- Name: events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    point_id uuid,
    kind character varying NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    source character varying,
    at timestamp(6) without time zone NOT NULL
);


--
-- Name: external_refs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.external_refs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    source character varying NOT NULL,
    external_id character varying NOT NULL,
    kind character varying NOT NULL,
    name character varying,
    target_type character varying,
    target_id uuid,
    note character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: feature_flags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feature_flags (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key character varying NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integrations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    driver character varying NOT NULL,
    name character varying NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    credentials text,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    last_error character varying,
    last_ok_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    poll_s integer DEFAULT 1800,
    polled_at timestamp(6) without time zone,
    inventory text
);


--
-- Name: invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    created_by_id uuid,
    accepted_by_id uuid,
    role character varying DEFAULT 'member'::character varying NOT NULL,
    code_digest character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    accepted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    site_id uuid,
    site_role character varying
);


--
-- Name: model_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_prices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider character varying NOT NULL,
    model character varying NOT NULL,
    input_per_mtok numeric(10,4) DEFAULT 0.0 NOT NULL,
    output_per_mtok numeric(10,4) DEFAULT 0.0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid,
    kind character varying NOT NULL,
    title character varying NOT NULL,
    body character varying,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    dedup_key character varying,
    read_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    responded_at timestamp(6) without time zone,
    response jsonb
);


--
-- Name: notify_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notify_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    point_id uuid NOT NULL,
    to_value jsonb,
    message character varying,
    channels character varying[] DEFAULT '{in_app,push}'::character varying[] NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: packages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.packages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    key character varying NOT NULL,
    name character varying NOT NULL,
    version character varying NOT NULL,
    source_url character varying NOT NULL,
    manifest jsonb DEFAULT '{}'::jsonb NOT NULL,
    installed jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: point_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.point_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    source_point_id uuid NOT NULL,
    target_point_id uuid NOT NULL,
    mode character varying DEFAULT 'mirror'::character varying NOT NULL,
    bidirectional boolean DEFAULT false NOT NULL,
    trigger_value jsonb,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: points; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.points (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    device_id uuid NOT NULL,
    area_id uuid,
    key character varying NOT NULL,
    name character varying NOT NULL,
    icon character varying,
    capability character varying NOT NULL,
    data_type character varying,
    device_class character varying,
    state_class character varying,
    unit character varying,
    options jsonb DEFAULT '[]'::jsonb NOT NULL,
    min numeric,
    max numeric,
    step numeric,
    writable boolean DEFAULT false NOT NULL,
    address jsonb DEFAULT '{}'::jsonb NOT NULL,
    scale numeric DEFAULT 1.0 NOT NULL,
    "offset" numeric DEFAULT 0.0 NOT NULL,
    deadband numeric,
    history character varying DEFAULT 'on_change'::character varying NOT NULL,
    history_interval_s integer,
    retention_days integer,
    pulse_ms integer,
    max_on_s integer,
    confirm character varying,
    risk character varying DEFAULT 'normal'::character varying NOT NULL,
    expose jsonb DEFAULT '{}'::jsonb NOT NULL,
    value jsonb,
    quality character varying DEFAULT 'good'::character varying NOT NULL,
    changed_at timestamp(6) without time zone,
    reported_at timestamp(6) without time zone,
    hidden boolean DEFAULT false NOT NULL,
    disabled boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    helper character varying,
    alexa_exposed boolean DEFAULT false NOT NULL,
    alexa_name character varying,
    attrs jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: push_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.push_subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    endpoint text NOT NULL,
    p256dh_key character varying NOT NULL,
    auth_key character varying NOT NULL,
    name character varying,
    user_agent character varying,
    last_used_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: reading_rollups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reading_rollups (
    point_id uuid NOT NULL,
    bucket character varying NOT NULL,
    starts_at timestamp(6) without time zone NOT NULL,
    min numeric,
    max numeric,
    avg numeric,
    sum numeric,
    last numeric,
    count integer DEFAULT 0 NOT NULL,
    on_seconds integer
);


--
-- Name: readings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.readings (
    point_id uuid NOT NULL,
    at timestamp(6) without time zone NOT NULL,
    value numeric,
    value_text text
)
PARTITION BY RANGE (at);


--
-- Name: readings_2026_10; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.readings_2026_10 (
    point_id uuid CONSTRAINT readings_point_id_not_null NOT NULL,
    at timestamp(6) without time zone CONSTRAINT readings_at_not_null NOT NULL,
    value numeric,
    value_text text
);


--
-- Name: readings_2026_11; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.readings_2026_11 (
    point_id uuid CONSTRAINT readings_point_id_not_null NOT NULL,
    at timestamp(6) without time zone CONSTRAINT readings_at_not_null NOT NULL,
    value numeric,
    value_text text
);


--
-- Name: readings_default; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.readings_default (
    point_id uuid CONSTRAINT readings_point_id_not_null NOT NULL,
    at timestamp(6) without time zone CONSTRAINT readings_at_not_null NOT NULL,
    value numeric,
    value_text text
);


--
-- Name: scenes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scenes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    name character varying NOT NULL,
    icon character varying,
    items jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    alexa_exposed boolean DEFAULT false NOT NULL,
    alexa_name character varying,
    shadow boolean DEFAULT false NOT NULL
);


--
-- Name: schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schedules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    point_id uuid,
    scene_id uuid,
    name character varying NOT NULL,
    command character varying,
    value jsonb,
    kind character varying DEFAULT 'time'::character varying NOT NULL,
    time_of_day character varying,
    offset_min integer DEFAULT 0 NOT NULL,
    days integer[] DEFAULT '{0,1,2,3,4,5,6}'::integer[] NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    next_run_at timestamp(6) without time zone,
    last_run_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: service_api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name character varying NOT NULL,
    token_digest character varying NOT NULL,
    scopes character varying[] DEFAULT '{}'::character varying[] NOT NULL,
    expires_at timestamp(6) without time zone,
    last_used_at timestamp(6) without time zone,
    revoked_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    site_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL
);


--
-- Name: shadow_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shadow_actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    automation_id uuid,
    automation_run_id uuid,
    scene_id uuid,
    action character varying NOT NULL,
    title character varying NOT NULL,
    detail character varying,
    effects jsonb DEFAULT '[]'::jsonb NOT NULL,
    executed boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: shadow_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shadow_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    source character varying NOT NULL,
    window_from timestamp(6) without time zone NOT NULL,
    window_to timestamp(6) without time zone NOT NULL,
    summary jsonb DEFAULT '{}'::jsonb NOT NULL,
    rows jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: site_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    site_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying DEFAULT 'resident'::character varying NOT NULL,
    area_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    expires_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    name character varying NOT NULL,
    kind character varying DEFAULT 'home'::character varying NOT NULL,
    timezone character varying DEFAULT 'America/Sao_Paulo'::character varying NOT NULL,
    address character varying,
    latitude numeric(9,6),
    longitude numeric(9,6),
    wallpaper character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    shadow boolean DEFAULT false NOT NULL
);


--
-- Name: solid_cable_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_cable_messages (
    id bigint NOT NULL,
    channel bytea NOT NULL,
    payload bytea NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    channel_hash bigint NOT NULL
);


--
-- Name: solid_cable_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_cable_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_cable_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_cable_messages_id_seq OWNED BY public.solid_cable_messages.id;


--
-- Name: solid_cache_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_cache_entries (
    id bigint NOT NULL,
    key bytea NOT NULL,
    value bytea NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    key_hash bigint NOT NULL,
    byte_size integer NOT NULL
);


--
-- Name: solid_cache_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_cache_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_cache_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_cache_entries_id_seq OWNED BY public.solid_cache_entries.id;


--
-- Name: solid_queue_batch_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_batch_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    batch_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_batch_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_batch_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_batch_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_batch_executions_id_seq OWNED BY public.solid_queue_batch_executions.id;


--
-- Name: solid_queue_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_batches (
    id bigint NOT NULL,
    active_job_batch_id character varying,
    description character varying,
    on_finish text,
    on_success text,
    on_failure text,
    metadata text,
    total_jobs integer DEFAULT 0 NOT NULL,
    completed_jobs integer DEFAULT 0 NOT NULL,
    failed_jobs integer DEFAULT 0 NOT NULL,
    enqueued_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    failed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_batches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_batches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_batches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_batches_id_seq OWNED BY public.solid_queue_batches.id;


--
-- Name: solid_queue_blocked_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_blocked_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    concurrency_key character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_blocked_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_blocked_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_blocked_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_blocked_executions_id_seq OWNED BY public.solid_queue_blocked_executions.id;


--
-- Name: solid_queue_claimed_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_claimed_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    process_id bigint,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_claimed_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_claimed_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_claimed_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_claimed_executions_id_seq OWNED BY public.solid_queue_claimed_executions.id;


--
-- Name: solid_queue_failed_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_failed_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    error text,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_failed_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_failed_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_failed_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_failed_executions_id_seq OWNED BY public.solid_queue_failed_executions.id;


--
-- Name: solid_queue_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_jobs (
    id bigint NOT NULL,
    queue_name character varying NOT NULL,
    class_name character varying NOT NULL,
    arguments text,
    priority integer DEFAULT 0 NOT NULL,
    active_job_id character varying,
    scheduled_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    concurrency_key character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    batch_id bigint
);


--
-- Name: solid_queue_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_jobs_id_seq OWNED BY public.solid_queue_jobs.id;


--
-- Name: solid_queue_pauses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_pauses (
    id bigint NOT NULL,
    queue_name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_pauses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_pauses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_pauses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_pauses_id_seq OWNED BY public.solid_queue_pauses.id;


--
-- Name: solid_queue_processes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_processes (
    id bigint NOT NULL,
    kind character varying NOT NULL,
    last_heartbeat_at timestamp(6) without time zone NOT NULL,
    supervisor_id bigint,
    pid integer NOT NULL,
    hostname character varying,
    metadata text,
    created_at timestamp(6) without time zone NOT NULL,
    name character varying NOT NULL
);


--
-- Name: solid_queue_processes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_processes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_processes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_processes_id_seq OWNED BY public.solid_queue_processes.id;


--
-- Name: solid_queue_ready_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_ready_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_ready_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_ready_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_ready_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_ready_executions_id_seq OWNED BY public.solid_queue_ready_executions.id;


--
-- Name: solid_queue_recurring_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_recurring_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    task_key character varying NOT NULL,
    run_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_recurring_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_recurring_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_recurring_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_recurring_executions_id_seq OWNED BY public.solid_queue_recurring_executions.id;


--
-- Name: solid_queue_recurring_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_recurring_tasks (
    id bigint NOT NULL,
    key character varying NOT NULL,
    schedule character varying NOT NULL,
    command character varying(2048),
    class_name character varying,
    arguments text,
    queue_name character varying,
    priority integer DEFAULT 0,
    static boolean DEFAULT true NOT NULL,
    description text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_recurring_tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_recurring_tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_recurring_tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_recurring_tasks_id_seq OWNED BY public.solid_queue_recurring_tasks.id;


--
-- Name: solid_queue_scheduled_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_scheduled_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    scheduled_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_scheduled_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_scheduled_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_scheduled_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_scheduled_executions_id_seq OWNED BY public.solid_queue_scheduled_executions.id;


--
-- Name: solid_queue_semaphores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_semaphores (
    id bigint NOT NULL,
    key character varying NOT NULL,
    value integer DEFAULT 1 NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_semaphores_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_semaphores_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_semaphores_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_semaphores_id_seq OWNED BY public.solid_queue_semaphores.id;


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid,
    source character varying(20) NOT NULL,
    external_id character varying NOT NULL,
    product_id character varying(100),
    base_plan_id character varying(100),
    offer_id character varying(100),
    plan character varying(20) DEFAULT 'free'::character varying NOT NULL,
    status character varying(20) NOT NULL,
    auto_renewing boolean,
    trial boolean DEFAULT false NOT NULL,
    expires_at timestamp(6) without time zone,
    linked_external_id character varying,
    verified_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: taggings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.taggings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    tag_id uuid NOT NULL,
    taggable_type character varying NOT NULL,
    taggable_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tags (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    name character varying NOT NULL,
    color character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying NOT NULL,
    trade_name character varying,
    document character varying,
    phone character varying,
    email character varying,
    city character varying,
    uf character varying(2),
    ibge_code character varying(7),
    plan character varying DEFAULT 'free'::character varying NOT NULL,
    plan_provider character varying(20),
    plan_expires_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    name character varying NOT NULL,
    email character varying NOT NULL,
    password_digest character varying,
    google_uid character varying,
    role character varying DEFAULT 'owner'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    dashboard_prefs jsonb DEFAULT '{}'::jsonb NOT NULL,
    disabled_at timestamp(6) without time zone
);


--
-- Name: readings_2026_10; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.readings ATTACH PARTITION public.readings_2026_10 FOR VALUES FROM ('2026-10-01 00:00:00') TO ('2026-11-01 00:00:00');


--
-- Name: readings_2026_11; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.readings ATTACH PARTITION public.readings_2026_11 FOR VALUES FROM ('2026-11-01 00:00:00') TO ('2026-12-01 00:00:00');


--
-- Name: readings_default; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.readings ATTACH PARTITION public.readings_default DEFAULT;


--
-- Name: solid_cable_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cable_messages ALTER COLUMN id SET DEFAULT nextval('public.solid_cable_messages_id_seq'::regclass);


--
-- Name: solid_cache_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cache_entries ALTER COLUMN id SET DEFAULT nextval('public.solid_cache_entries_id_seq'::regclass);


--
-- Name: solid_queue_batch_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_batch_executions_id_seq'::regclass);


--
-- Name: solid_queue_batches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batches ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_batches_id_seq'::regclass);


--
-- Name: solid_queue_blocked_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_blocked_executions_id_seq'::regclass);


--
-- Name: solid_queue_claimed_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_claimed_executions_id_seq'::regclass);


--
-- Name: solid_queue_failed_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_failed_executions_id_seq'::regclass);


--
-- Name: solid_queue_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_jobs ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_jobs_id_seq'::regclass);


--
-- Name: solid_queue_pauses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_pauses ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_pauses_id_seq'::regclass);


--
-- Name: solid_queue_processes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_processes ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_processes_id_seq'::regclass);


--
-- Name: solid_queue_ready_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_ready_executions_id_seq'::regclass);


--
-- Name: solid_queue_recurring_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_recurring_executions_id_seq'::regclass);


--
-- Name: solid_queue_recurring_tasks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_tasks ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_recurring_tasks_id_seq'::regclass);


--
-- Name: solid_queue_scheduled_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_scheduled_executions_id_seq'::regclass);


--
-- Name: solid_queue_semaphores id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_semaphores ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_semaphores_id_seq'::regclass);


--
-- Name: active_storage_attachments active_storage_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT active_storage_attachments_pkey PRIMARY KEY (id);


--
-- Name: active_storage_blobs active_storage_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs
    ADD CONSTRAINT active_storage_blobs_pkey PRIMARY KEY (id);


--
-- Name: active_storage_variant_records active_storage_variant_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT active_storage_variant_records_pkey PRIMARY KEY (id);


--
-- Name: ai_accounts ai_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_accounts
    ADD CONSTRAINT ai_accounts_pkey PRIMARY KEY (id);


--
-- Name: ai_calls ai_calls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_calls
    ADD CONSTRAINT ai_calls_pkey PRIMARY KEY (id);


--
-- Name: ai_plan_features ai_plan_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_plan_features
    ADD CONSTRAINT ai_plan_features_pkey PRIMARY KEY (id);


--
-- Name: ai_tier_configs ai_tier_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_tier_configs
    ADD CONSTRAINT ai_tier_configs_pkey PRIMARY KEY (id);


--
-- Name: ai_usages ai_usages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usages
    ADD CONSTRAINT ai_usages_pkey PRIMARY KEY (id);


--
-- Name: alert_rules alert_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_rules
    ADD CONSTRAINT alert_rules_pkey PRIMARY KEY (id);


--
-- Name: alerts alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT alerts_pkey PRIMARY KEY (id);


--
-- Name: api_tokens api_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_tokens
    ADD CONSTRAINT api_tokens_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: areas areas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas
    ADD CONSTRAINT areas_pkey PRIMARY KEY (id);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: automation_runs automation_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_runs
    ADD CONSTRAINT automation_runs_pkey PRIMARY KEY (id);


--
-- Name: automation_versions automation_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_versions
    ADD CONSTRAINT automation_versions_pkey PRIMARY KEY (id);


--
-- Name: automations automations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automations
    ADD CONSTRAINT automations_pkey PRIMARY KEY (id);


--
-- Name: blueprints blueprints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blueprints
    ADD CONSTRAINT blueprints_pkey PRIMARY KEY (id);


--
-- Name: commands commands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands
    ADD CONSTRAINT commands_pkey PRIMARY KEY (id);


--
-- Name: dashboard_versions dashboard_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dashboard_versions
    ADD CONSTRAINT dashboard_versions_pkey PRIMARY KEY (id);


--
-- Name: dashboards dashboards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dashboards
    ADD CONSTRAINT dashboards_pkey PRIMARY KEY (id);


--
-- Name: dataset_records dataset_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dataset_records
    ADD CONSTRAINT dataset_records_pkey PRIMARY KEY (id);


--
-- Name: datasets datasets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.datasets
    ADD CONSTRAINT datasets_pkey PRIMARY KEY (id);


--
-- Name: device_tokens device_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tokens
    ADD CONSTRAINT device_tokens_pkey PRIMARY KEY (id);


--
-- Name: devices devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


--
-- Name: external_refs external_refs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_refs
    ADD CONSTRAINT external_refs_pkey PRIMARY KEY (id);


--
-- Name: feature_flags feature_flags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feature_flags
    ADD CONSTRAINT feature_flags_pkey PRIMARY KEY (id);


--
-- Name: integrations integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integrations
    ADD CONSTRAINT integrations_pkey PRIMARY KEY (id);


--
-- Name: invites invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT invites_pkey PRIMARY KEY (id);


--
-- Name: model_prices model_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_prices
    ADD CONSTRAINT model_prices_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: notify_rules notify_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notify_rules
    ADD CONSTRAINT notify_rules_pkey PRIMARY KEY (id);


--
-- Name: packages packages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT packages_pkey PRIMARY KEY (id);


--
-- Name: point_links point_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.point_links
    ADD CONSTRAINT point_links_pkey PRIMARY KEY (id);


--
-- Name: points points_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.points
    ADD CONSTRAINT points_pkey PRIMARY KEY (id);


--
-- Name: push_subscriptions push_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_subscriptions
    ADD CONSTRAINT push_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: scenes scenes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenes
    ADD CONSTRAINT scenes_pkey PRIMARY KEY (id);


--
-- Name: schedules schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedules
    ADD CONSTRAINT schedules_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: service_api_keys service_api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_api_keys
    ADD CONSTRAINT service_api_keys_pkey PRIMARY KEY (id);


--
-- Name: shadow_actions shadow_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shadow_actions
    ADD CONSTRAINT shadow_actions_pkey PRIMARY KEY (id);


--
-- Name: shadow_reports shadow_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shadow_reports
    ADD CONSTRAINT shadow_reports_pkey PRIMARY KEY (id);


--
-- Name: site_memberships site_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_memberships
    ADD CONSTRAINT site_memberships_pkey PRIMARY KEY (id);


--
-- Name: sites sites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_pkey PRIMARY KEY (id);


--
-- Name: solid_cable_messages solid_cable_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cable_messages
    ADD CONSTRAINT solid_cable_messages_pkey PRIMARY KEY (id);


--
-- Name: solid_cache_entries solid_cache_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cache_entries
    ADD CONSTRAINT solid_cache_entries_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_batch_executions solid_queue_batch_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions
    ADD CONSTRAINT solid_queue_batch_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_batches solid_queue_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batches
    ADD CONSTRAINT solid_queue_batches_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_blocked_executions solid_queue_blocked_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions
    ADD CONSTRAINT solid_queue_blocked_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_claimed_executions solid_queue_claimed_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions
    ADD CONSTRAINT solid_queue_claimed_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_failed_executions solid_queue_failed_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions
    ADD CONSTRAINT solid_queue_failed_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_jobs solid_queue_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_jobs
    ADD CONSTRAINT solid_queue_jobs_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_pauses solid_queue_pauses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_pauses
    ADD CONSTRAINT solid_queue_pauses_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_processes solid_queue_processes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_processes
    ADD CONSTRAINT solid_queue_processes_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_ready_executions solid_queue_ready_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions
    ADD CONSTRAINT solid_queue_ready_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_recurring_executions solid_queue_recurring_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions
    ADD CONSTRAINT solid_queue_recurring_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_recurring_tasks solid_queue_recurring_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_tasks
    ADD CONSTRAINT solid_queue_recurring_tasks_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_scheduled_executions solid_queue_scheduled_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions
    ADD CONSTRAINT solid_queue_scheduled_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_semaphores solid_queue_semaphores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_semaphores
    ADD CONSTRAINT solid_queue_semaphores_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: taggings taggings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_pkey PRIMARY KEY (id);


--
-- Name: tags tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: index_active_storage_attachments_on_blob_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_attachments_on_blob_id ON public.active_storage_attachments USING btree (blob_id);


--
-- Name: index_active_storage_attachments_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_attachments_uniqueness ON public.active_storage_attachments USING btree (record_type, record_id, name, blob_id);


--
-- Name: index_active_storage_blobs_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_blobs_on_key ON public.active_storage_blobs USING btree (key);


--
-- Name: index_active_storage_variant_records_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_variant_records_uniqueness ON public.active_storage_variant_records USING btree (blob_id, variation_digest);


--
-- Name: index_ai_accounts_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_accounts_on_tenant_id ON public.ai_accounts USING btree (tenant_id);


--
-- Name: index_ai_accounts_on_tenant_id_and_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_accounts_on_tenant_id_and_provider ON public.ai_accounts USING btree (tenant_id, provider);


--
-- Name: index_ai_calls_on_automation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_calls_on_automation_id ON public.ai_calls USING btree (automation_id);


--
-- Name: index_ai_calls_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_calls_on_site_id ON public.ai_calls USING btree (site_id);


--
-- Name: index_ai_calls_on_tenant_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_calls_on_tenant_id_and_created_at ON public.ai_calls USING btree (tenant_id, created_at);


--
-- Name: index_ai_plan_features_on_feature_and_plan; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_plan_features_on_feature_and_plan ON public.ai_plan_features USING btree (feature, plan);


--
-- Name: index_ai_tier_configs_on_tier; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_tier_configs_on_tier ON public.ai_tier_configs USING btree (tier);


--
-- Name: index_ai_usages_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_usages_on_tenant_id ON public.ai_usages USING btree (tenant_id);


--
-- Name: index_ai_usages_on_tenant_id_and_feature_and_period; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_usages_on_tenant_id_and_feature_and_period ON public.ai_usages USING btree (tenant_id, feature, period);


--
-- Name: index_alert_rules_on_point_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alert_rules_on_point_id ON public.alert_rules USING btree (point_id);


--
-- Name: index_alert_rules_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alert_rules_on_site_id ON public.alert_rules USING btree (site_id);


--
-- Name: index_alert_rules_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alert_rules_on_tenant_id ON public.alert_rules USING btree (tenant_id);


--
-- Name: index_alerts_on_acked_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alerts_on_acked_by_id ON public.alerts USING btree (acked_by_id);


--
-- Name: index_alerts_on_alert_rule_id_and_opened_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alerts_on_alert_rule_id_and_opened_at ON public.alerts USING btree (alert_rule_id, opened_at);


--
-- Name: index_alerts_on_point_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alerts_on_point_id ON public.alerts USING btree (point_id);


--
-- Name: index_alerts_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alerts_on_site_id ON public.alerts USING btree (site_id);


--
-- Name: index_alerts_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alerts_on_tenant_id ON public.alerts USING btree (tenant_id);


--
-- Name: index_alerts_open_per_rule; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_alerts_open_per_rule ON public.alerts USING btree (alert_rule_id) WHERE (resolved_at IS NULL);


--
-- Name: index_api_tokens_on_access_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_api_tokens_on_access_token_digest ON public.api_tokens USING btree (access_token_digest);


--
-- Name: index_api_tokens_on_client; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_tokens_on_client ON public.api_tokens USING btree (client);


--
-- Name: index_api_tokens_on_previous_refresh_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_tokens_on_previous_refresh_token_digest ON public.api_tokens USING btree (previous_refresh_token_digest);


--
-- Name: index_api_tokens_on_refresh_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_api_tokens_on_refresh_token_digest ON public.api_tokens USING btree (refresh_token_digest);


--
-- Name: index_api_tokens_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_tokens_on_site_id ON public.api_tokens USING btree (site_id);


--
-- Name: index_api_tokens_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_tokens_on_user_id ON public.api_tokens USING btree (user_id);


--
-- Name: index_areas_on_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_areas_on_parent_id ON public.areas USING btree (parent_id);


--
-- Name: index_areas_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_areas_on_site_id ON public.areas USING btree (site_id);


--
-- Name: index_areas_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_areas_on_tenant_id ON public.areas USING btree (tenant_id);


--
-- Name: index_audit_events_on_auditable_type_and_auditable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_auditable_type_and_auditable_id ON public.audit_events USING btree (auditable_type, auditable_id);


--
-- Name: index_audit_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_tenant_id ON public.audit_events USING btree (tenant_id);


--
-- Name: index_automation_runs_on_automation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_runs_on_automation_id ON public.automation_runs USING btree (automation_id);


--
-- Name: index_automation_runs_on_automation_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_runs_on_automation_id_and_created_at ON public.automation_runs USING btree (automation_id, created_at);


--
-- Name: index_automation_runs_on_cause_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_runs_on_cause_run_id ON public.automation_runs USING btree (cause_run_id);


--
-- Name: index_automation_runs_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_runs_on_site_id ON public.automation_runs USING btree (site_id);


--
-- Name: index_automation_runs_on_site_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_runs_on_site_id_and_status ON public.automation_runs USING btree (site_id, status);


--
-- Name: index_automation_runs_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_runs_on_tenant_id ON public.automation_runs USING btree (tenant_id);


--
-- Name: index_automation_versions_on_author_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_versions_on_author_id ON public.automation_versions USING btree (author_id);


--
-- Name: index_automation_versions_on_automation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_versions_on_automation_id ON public.automation_versions USING btree (automation_id);


--
-- Name: index_automation_versions_on_automation_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_automation_versions_on_automation_id_and_version ON public.automation_versions USING btree (automation_id, version);


--
-- Name: index_automation_versions_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_versions_on_tenant_id ON public.automation_versions USING btree (tenant_id);


--
-- Name: index_automations_on_area_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automations_on_area_id ON public.automations USING btree (area_id);


--
-- Name: index_automations_on_blueprint_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automations_on_blueprint_id ON public.automations USING btree (blueprint_id);


--
-- Name: index_automations_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automations_on_site_id ON public.automations USING btree (site_id);


--
-- Name: index_automations_on_site_id_and_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automations_on_site_id_and_kind ON public.automations USING btree (site_id, kind);


--
-- Name: index_automations_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automations_on_tenant_id ON public.automations USING btree (tenant_id);


--
-- Name: index_automations_on_webhook_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_automations_on_webhook_token ON public.automations USING btree (webhook_token);


--
-- Name: index_blueprints_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_blueprints_on_site_id ON public.blueprints USING btree (site_id);


--
-- Name: index_blueprints_on_site_id_and_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_blueprints_on_site_id_and_source ON public.blueprints USING btree (site_id, source) WHERE ((source)::text ~~ 'builtin:%'::text);


--
-- Name: index_blueprints_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_blueprints_on_tenant_id ON public.blueprints USING btree (tenant_id);


--
-- Name: index_commands_on_automation_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commands_on_automation_run_id ON public.commands USING btree (automation_run_id);


--
-- Name: index_commands_on_point_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commands_on_point_id_and_created_at ON public.commands USING btree (point_id, created_at DESC);


--
-- Name: index_commands_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commands_on_site_id ON public.commands USING btree (site_id);


--
-- Name: index_commands_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commands_on_tenant_id ON public.commands USING btree (tenant_id);


--
-- Name: index_commands_on_tenant_id_and_client_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_commands_on_tenant_id_and_client_uuid ON public.commands USING btree (tenant_id, client_uuid) WHERE (client_uuid IS NOT NULL);


--
-- Name: index_commands_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commands_on_user_id ON public.commands USING btree (user_id);


--
-- Name: index_dashboard_versions_on_author_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dashboard_versions_on_author_id ON public.dashboard_versions USING btree (author_id);


--
-- Name: index_dashboard_versions_on_dashboard_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dashboard_versions_on_dashboard_id ON public.dashboard_versions USING btree (dashboard_id);


--
-- Name: index_dashboard_versions_on_dashboard_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_dashboard_versions_on_dashboard_id_and_version ON public.dashboard_versions USING btree (dashboard_id, version);


--
-- Name: index_dashboard_versions_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dashboard_versions_on_tenant_id ON public.dashboard_versions USING btree (tenant_id);


--
-- Name: index_dashboards_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dashboards_on_site_id ON public.dashboards USING btree (site_id);


--
-- Name: index_dashboards_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dashboards_on_tenant_id ON public.dashboards USING btree (tenant_id);


--
-- Name: index_dataset_records_on_dataset_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dataset_records_on_dataset_id_and_created_at ON public.dataset_records USING btree (dataset_id, created_at);


--
-- Name: index_datasets_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_datasets_on_site_id ON public.datasets USING btree (site_id);


--
-- Name: index_datasets_on_site_id_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_datasets_on_site_id_and_key ON public.datasets USING btree (site_id, key);


--
-- Name: index_datasets_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_datasets_on_tenant_id ON public.datasets USING btree (tenant_id);


--
-- Name: index_device_tokens_on_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_device_tokens_on_token ON public.device_tokens USING btree (token);


--
-- Name: index_device_tokens_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_device_tokens_on_user_id ON public.device_tokens USING btree (user_id);


--
-- Name: index_devices_on_area_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_devices_on_area_id ON public.devices USING btree (area_id);


--
-- Name: index_devices_on_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_devices_on_external_id ON public.devices USING btree (external_id);


--
-- Name: index_devices_on_integration_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_devices_on_integration_id ON public.devices USING btree (integration_id);


--
-- Name: index_devices_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_devices_on_site_id ON public.devices USING btree (site_id);


--
-- Name: index_devices_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_devices_on_tenant_id ON public.devices USING btree (tenant_id);


--
-- Name: index_events_on_point_id_and_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_point_id_and_at ON public.events USING btree (point_id, at DESC);


--
-- Name: index_events_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_site_id ON public.events USING btree (site_id);


--
-- Name: index_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_tenant_id ON public.events USING btree (tenant_id);


--
-- Name: index_external_refs_on_site_id_and_source_and_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_external_refs_on_site_id_and_source_and_external_id ON public.external_refs USING btree (site_id, source, external_id);


--
-- Name: index_external_refs_on_target_type_and_target_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_external_refs_on_target_type_and_target_id ON public.external_refs USING btree (target_type, target_id);


--
-- Name: index_feature_flags_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_feature_flags_on_key ON public.feature_flags USING btree (key);


--
-- Name: index_integrations_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_integrations_on_site_id ON public.integrations USING btree (site_id);


--
-- Name: index_integrations_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_integrations_on_tenant_id ON public.integrations USING btree (tenant_id);


--
-- Name: index_invites_on_accepted_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_invites_on_accepted_by_id ON public.invites USING btree (accepted_by_id);


--
-- Name: index_invites_on_code_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_invites_on_code_digest ON public.invites USING btree (code_digest);


--
-- Name: index_invites_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_invites_on_created_by_id ON public.invites USING btree (created_by_id);


--
-- Name: index_invites_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_invites_on_tenant_id ON public.invites USING btree (tenant_id);


--
-- Name: index_model_prices_on_provider_and_model; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_model_prices_on_provider_and_model ON public.model_prices USING btree (provider, model);


--
-- Name: index_notifications_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_tenant_id ON public.notifications USING btree (tenant_id);


--
-- Name: index_notifications_on_tenant_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_tenant_id_and_created_at ON public.notifications USING btree (tenant_id, created_at);


--
-- Name: index_notifications_on_tenant_id_and_dedup_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_notifications_on_tenant_id_and_dedup_key ON public.notifications USING btree (tenant_id, dedup_key) WHERE (dedup_key IS NOT NULL);


--
-- Name: index_notifications_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_user_id ON public.notifications USING btree (user_id);


--
-- Name: index_notify_rules_on_point_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notify_rules_on_point_id ON public.notify_rules USING btree (point_id);


--
-- Name: index_notify_rules_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notify_rules_on_site_id ON public.notify_rules USING btree (site_id);


--
-- Name: index_notify_rules_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notify_rules_on_tenant_id ON public.notify_rules USING btree (tenant_id);


--
-- Name: index_packages_on_site_id_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_packages_on_site_id_and_key ON public.packages USING btree (site_id, key);


--
-- Name: index_packages_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_packages_on_tenant_id ON public.packages USING btree (tenant_id);


--
-- Name: index_point_links_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_point_links_on_site_id ON public.point_links USING btree (site_id);


--
-- Name: index_point_links_on_source_point_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_point_links_on_source_point_id ON public.point_links USING btree (source_point_id);


--
-- Name: index_point_links_on_source_point_id_and_target_point_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_point_links_on_source_point_id_and_target_point_id ON public.point_links USING btree (source_point_id, target_point_id);


--
-- Name: index_point_links_on_target_point_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_point_links_on_target_point_id ON public.point_links USING btree (target_point_id);


--
-- Name: index_point_links_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_point_links_on_tenant_id ON public.point_links USING btree (tenant_id);


--
-- Name: index_points_on_area_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_points_on_area_id ON public.points USING btree (area_id);


--
-- Name: index_points_on_device_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_points_on_device_id ON public.points USING btree (device_id);


--
-- Name: index_points_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_points_on_site_id ON public.points USING btree (site_id);


--
-- Name: index_points_on_site_id_and_helper; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_points_on_site_id_and_helper ON public.points USING btree (site_id, helper) WHERE (helper IS NOT NULL);


--
-- Name: index_points_on_site_id_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_points_on_site_id_and_key ON public.points USING btree (site_id, key);


--
-- Name: index_points_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_points_on_tenant_id ON public.points USING btree (tenant_id);


--
-- Name: index_push_subscriptions_on_endpoint; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_push_subscriptions_on_endpoint ON public.push_subscriptions USING btree (endpoint);


--
-- Name: index_push_subscriptions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_push_subscriptions_on_user_id ON public.push_subscriptions USING btree (user_id);


--
-- Name: index_reading_rollups_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_reading_rollups_uniqueness ON public.reading_rollups USING btree (point_id, bucket, starts_at);


--
-- Name: index_readings_on_point_id_and_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_readings_on_point_id_and_at ON ONLY public.readings USING btree (point_id, at DESC);


--
-- Name: index_scenes_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_scenes_on_site_id ON public.scenes USING btree (site_id);


--
-- Name: index_scenes_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_scenes_on_tenant_id ON public.scenes USING btree (tenant_id);


--
-- Name: index_schedules_on_next_run_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_schedules_on_next_run_at ON public.schedules USING btree (next_run_at) WHERE enabled;


--
-- Name: index_schedules_on_point_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_schedules_on_point_id ON public.schedules USING btree (point_id);


--
-- Name: index_schedules_on_scene_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_schedules_on_scene_id ON public.schedules USING btree (scene_id);


--
-- Name: index_schedules_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_schedules_on_site_id ON public.schedules USING btree (site_id);


--
-- Name: index_schedules_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_schedules_on_tenant_id ON public.schedules USING btree (tenant_id);


--
-- Name: index_service_api_keys_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_service_api_keys_on_token_digest ON public.service_api_keys USING btree (token_digest);


--
-- Name: index_service_api_keys_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_service_api_keys_on_user_id ON public.service_api_keys USING btree (user_id);


--
-- Name: index_shadow_actions_on_automation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_shadow_actions_on_automation_id ON public.shadow_actions USING btree (automation_id);


--
-- Name: index_shadow_actions_on_scene_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_shadow_actions_on_scene_id ON public.shadow_actions USING btree (scene_id);


--
-- Name: index_shadow_actions_on_site_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_shadow_actions_on_site_id_and_created_at ON public.shadow_actions USING btree (site_id, created_at);


--
-- Name: index_shadow_reports_on_site_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_shadow_reports_on_site_id_and_created_at ON public.shadow_reports USING btree (site_id, created_at);


--
-- Name: index_site_memberships_on_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_site_memberships_on_site_id ON public.site_memberships USING btree (site_id);


--
-- Name: index_site_memberships_on_site_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_site_memberships_on_site_id_and_user_id ON public.site_memberships USING btree (site_id, user_id);


--
-- Name: index_site_memberships_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_site_memberships_on_tenant_id ON public.site_memberships USING btree (tenant_id);


--
-- Name: index_site_memberships_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_site_memberships_on_user_id ON public.site_memberships USING btree (user_id);


--
-- Name: index_sites_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sites_on_tenant_id ON public.sites USING btree (tenant_id);


--
-- Name: index_solid_cable_messages_on_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cable_messages_on_channel ON public.solid_cable_messages USING btree (channel);


--
-- Name: index_solid_cable_messages_on_channel_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cable_messages_on_channel_hash ON public.solid_cable_messages USING btree (channel_hash);


--
-- Name: index_solid_cable_messages_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cable_messages_on_created_at ON public.solid_cable_messages USING btree (created_at);


--
-- Name: index_solid_cache_entries_on_byte_size; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cache_entries_on_byte_size ON public.solid_cache_entries USING btree (byte_size);


--
-- Name: index_solid_cache_entries_on_key_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_cache_entries_on_key_hash ON public.solid_cache_entries USING btree (key_hash);


--
-- Name: index_solid_cache_entries_on_key_hash_and_byte_size; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cache_entries_on_key_hash_and_byte_size ON public.solid_cache_entries USING btree (key_hash, byte_size);


--
-- Name: index_solid_queue_batch_executions_on_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_batch_executions_on_batch_id ON public.solid_queue_batch_executions USING btree (batch_id);


--
-- Name: index_solid_queue_batch_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_batch_executions_on_job_id ON public.solid_queue_batch_executions USING btree (job_id);


--
-- Name: index_solid_queue_batches_on_active_job_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_batches_on_active_job_batch_id ON public.solid_queue_batches USING btree (active_job_batch_id);


--
-- Name: index_solid_queue_batches_on_finished_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_batches_on_finished_at ON public.solid_queue_batches USING btree (finished_at);


--
-- Name: index_solid_queue_blocked_executions_for_maintenance; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_blocked_executions_for_maintenance ON public.solid_queue_blocked_executions USING btree (expires_at, concurrency_key);


--
-- Name: index_solid_queue_blocked_executions_for_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_blocked_executions_for_release ON public.solid_queue_blocked_executions USING btree (concurrency_key, priority, job_id);


--
-- Name: index_solid_queue_blocked_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_blocked_executions_on_job_id ON public.solid_queue_blocked_executions USING btree (job_id);


--
-- Name: index_solid_queue_claimed_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_claimed_executions_on_job_id ON public.solid_queue_claimed_executions USING btree (job_id);


--
-- Name: index_solid_queue_claimed_executions_on_process_id_and_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_claimed_executions_on_process_id_and_job_id ON public.solid_queue_claimed_executions USING btree (process_id, job_id);


--
-- Name: index_solid_queue_dispatch_all; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_dispatch_all ON public.solid_queue_scheduled_executions USING btree (scheduled_at, priority, job_id);


--
-- Name: index_solid_queue_failed_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_failed_executions_on_job_id ON public.solid_queue_failed_executions USING btree (job_id);


--
-- Name: index_solid_queue_jobs_for_alerting; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_for_alerting ON public.solid_queue_jobs USING btree (scheduled_at, finished_at);


--
-- Name: index_solid_queue_jobs_for_filtering; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_for_filtering ON public.solid_queue_jobs USING btree (queue_name, finished_at);


--
-- Name: index_solid_queue_jobs_on_active_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_active_job_id ON public.solid_queue_jobs USING btree (active_job_id);


--
-- Name: index_solid_queue_jobs_on_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_batch_id ON public.solid_queue_jobs USING btree (batch_id);


--
-- Name: index_solid_queue_jobs_on_class_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_class_name ON public.solid_queue_jobs USING btree (class_name);


--
-- Name: index_solid_queue_jobs_on_finished_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_finished_at ON public.solid_queue_jobs USING btree (finished_at);


--
-- Name: index_solid_queue_pauses_on_queue_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_pauses_on_queue_name ON public.solid_queue_pauses USING btree (queue_name);


--
-- Name: index_solid_queue_poll_all; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_poll_all ON public.solid_queue_ready_executions USING btree (priority, job_id);


--
-- Name: index_solid_queue_poll_by_queue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_poll_by_queue ON public.solid_queue_ready_executions USING btree (queue_name, priority, job_id);


--
-- Name: index_solid_queue_processes_on_last_heartbeat_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_processes_on_last_heartbeat_at ON public.solid_queue_processes USING btree (last_heartbeat_at);


--
-- Name: index_solid_queue_processes_on_name_and_supervisor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_processes_on_name_and_supervisor_id ON public.solid_queue_processes USING btree (name, supervisor_id);


--
-- Name: index_solid_queue_processes_on_supervisor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_processes_on_supervisor_id ON public.solid_queue_processes USING btree (supervisor_id);


--
-- Name: index_solid_queue_ready_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_ready_executions_on_job_id ON public.solid_queue_ready_executions USING btree (job_id);


--
-- Name: index_solid_queue_recurring_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_executions_on_job_id ON public.solid_queue_recurring_executions USING btree (job_id);


--
-- Name: index_solid_queue_recurring_executions_on_task_key_and_run_at; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_executions_on_task_key_and_run_at ON public.solid_queue_recurring_executions USING btree (task_key, run_at);


--
-- Name: index_solid_queue_recurring_tasks_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_tasks_on_key ON public.solid_queue_recurring_tasks USING btree (key);


--
-- Name: index_solid_queue_recurring_tasks_on_static; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_recurring_tasks_on_static ON public.solid_queue_recurring_tasks USING btree (static);


--
-- Name: index_solid_queue_scheduled_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_scheduled_executions_on_job_id ON public.solid_queue_scheduled_executions USING btree (job_id);


--
-- Name: index_solid_queue_semaphores_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_semaphores_on_expires_at ON public.solid_queue_semaphores USING btree (expires_at);


--
-- Name: index_solid_queue_semaphores_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_semaphores_on_key ON public.solid_queue_semaphores USING btree (key);


--
-- Name: index_solid_queue_semaphores_on_key_and_value; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_semaphores_on_key_and_value ON public.solid_queue_semaphores USING btree (key, value);


--
-- Name: index_subscriptions_on_source_and_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_subscriptions_on_source_and_external_id ON public.subscriptions USING btree (source, external_id);


--
-- Name: index_subscriptions_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_subscriptions_on_tenant_id ON public.subscriptions USING btree (tenant_id);


--
-- Name: index_subscriptions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_subscriptions_on_user_id ON public.subscriptions USING btree (user_id);


--
-- Name: index_taggings_on_tag_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_taggings_on_tag_id ON public.taggings USING btree (tag_id);


--
-- Name: index_taggings_on_taggable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_taggings_on_taggable ON public.taggings USING btree (taggable_type, taggable_id);


--
-- Name: index_taggings_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_taggings_on_tenant_id ON public.taggings USING btree (tenant_id);


--
-- Name: index_taggings_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_taggings_uniqueness ON public.taggings USING btree (tag_id, taggable_type, taggable_id);


--
-- Name: index_tags_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tags_on_tenant_id ON public.tags USING btree (tenant_id);


--
-- Name: index_tags_on_tenant_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tags_on_tenant_id_and_name ON public.tags USING btree (tenant_id, name);


--
-- Name: index_users_on_google_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_google_uid ON public.users USING btree (google_uid) WHERE (google_uid IS NOT NULL);


--
-- Name: index_users_on_lower_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_lower_email ON public.users USING btree (lower((email)::text));


--
-- Name: index_users_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_tenant_id ON public.users USING btree (tenant_id);


--
-- Name: readings_2026_10_point_id_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX readings_2026_10_point_id_at_idx ON public.readings_2026_10 USING btree (point_id, at DESC);


--
-- Name: readings_2026_11_point_id_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX readings_2026_11_point_id_at_idx ON public.readings_2026_11 USING btree (point_id, at DESC);


--
-- Name: readings_default_point_id_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX readings_default_point_id_at_idx ON public.readings_default USING btree (point_id, at DESC);


--
-- Name: readings_2026_10_point_id_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.index_readings_on_point_id_and_at ATTACH PARTITION public.readings_2026_10_point_id_at_idx;


--
-- Name: readings_2026_11_point_id_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.index_readings_on_point_id_and_at ATTACH PARTITION public.readings_2026_11_point_id_at_idx;


--
-- Name: readings_default_point_id_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.index_readings_on_point_id_and_at ATTACH PARTITION public.readings_default_point_id_at_idx;


--
-- Name: automation_versions fk_rails_002e3d5c41; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_versions
    ADD CONSTRAINT fk_rails_002e3d5c41 FOREIGN KEY (author_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: notify_rules fk_rails_073e957909; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notify_rules
    ADD CONSTRAINT fk_rails_073e957909 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: schedules fk_rails_084a346429; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedules
    ADD CONSTRAINT fk_rails_084a346429 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: subscriptions fk_rails_0cedf77d81; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT fk_rails_0cedf77d81 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: blueprints fk_rails_0da735ddc0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blueprints
    ADD CONSTRAINT fk_rails_0da735ddc0 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: shadow_actions fk_rails_0e3356996d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shadow_actions
    ADD CONSTRAINT fk_rails_0e3356996d FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: devices fk_rails_12ad68c8f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT fk_rails_12ad68c8f1 FOREIGN KEY (area_id) REFERENCES public.areas(id) ON DELETE SET NULL;


--
-- Name: users fk_rails_135c8f54b2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_rails_135c8f54b2 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: commands fk_rails_13b26c56f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands
    ADD CONSTRAINT fk_rails_13b26c56f0 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: service_api_keys fk_rails_15adfd5bf0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_api_keys
    ADD CONSTRAINT fk_rails_15adfd5bf0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: point_links fk_rails_19bdc1fe3f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.point_links
    ADD CONSTRAINT fk_rails_19bdc1fe3f FOREIGN KEY (source_point_id) REFERENCES public.points(id) ON DELETE CASCADE;


--
-- Name: dataset_records fk_rails_1e3a8433bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dataset_records
    ADD CONSTRAINT fk_rails_1e3a8433bd FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: ai_accounts fk_rails_1f9f9e2934; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_accounts
    ADD CONSTRAINT fk_rails_1f9f9e2934 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: alert_rules fk_rails_20afd75383; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_rules
    ADD CONSTRAINT fk_rails_20afd75383 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: schedules fk_rails_228e8ae418; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedules
    ADD CONSTRAINT fk_rails_228e8ae418 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: alerts fk_rails_23dded3105; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT fk_rails_23dded3105 FOREIGN KEY (point_id) REFERENCES public.points(id) ON DELETE CASCADE;


--
-- Name: devices fk_rails_244482c7d4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT fk_rails_244482c7d4 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: site_memberships fk_rails_247db98153; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_memberships
    ADD CONSTRAINT fk_rails_247db98153 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: scenes fk_rails_28279ad49b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenes
    ADD CONSTRAINT fk_rails_28279ad49b FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: automations fk_rails_2d0b9707e7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automations
    ADD CONSTRAINT fk_rails_2d0b9707e7 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: automations fk_rails_2f12249e60; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automations
    ADD CONSTRAINT fk_rails_2f12249e60 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: solid_queue_recurring_executions fk_rails_318a5533ed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions
    ADD CONSTRAINT fk_rails_318a5533ed FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: schedules fk_rails_324e2727f9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedules
    ADD CONSTRAINT fk_rails_324e2727f9 FOREIGN KEY (point_id) REFERENCES public.points(id) ON DELETE CASCADE;


--
-- Name: automation_runs fk_rails_35ff6ac887; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_runs
    ADD CONSTRAINT fk_rails_35ff6ac887 FOREIGN KEY (automation_id) REFERENCES public.automations(id) ON DELETE CASCADE;


--
-- Name: commands fk_rails_37053e57d9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands
    ADD CONSTRAINT fk_rails_37053e57d9 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: commands fk_rails_370b310a97; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands
    ADD CONSTRAINT fk_rails_370b310a97 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: datasets fk_rails_390f4d8005; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.datasets
    ADD CONSTRAINT fk_rails_390f4d8005 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: automation_versions fk_rails_3987ae7367; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_versions
    ADD CONSTRAINT fk_rails_3987ae7367 FOREIGN KEY (automation_id) REFERENCES public.automations(id) ON DELETE CASCADE;


--
-- Name: solid_queue_failed_executions fk_rails_39bbc7a631; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions
    ADD CONSTRAINT fk_rails_39bbc7a631 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: commands fk_rails_3b93c53e4d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands
    ADD CONSTRAINT fk_rails_3b93c53e4d FOREIGN KEY (point_id) REFERENCES public.points(id) ON DELETE CASCADE;


--
-- Name: invites fk_rails_3d7426a003; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT fk_rails_3d7426a003 FOREIGN KEY (accepted_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: blueprints fk_rails_42bb587701; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blueprints
    ADD CONSTRAINT fk_rails_42bb587701 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: push_subscriptions fk_rails_43d43720fc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_subscriptions
    ADD CONSTRAINT fk_rails_43d43720fc FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: external_refs fk_rails_47beccf1f4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_refs
    ADD CONSTRAINT fk_rails_47beccf1f4 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: events fk_rails_4b008cd1c8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_4b008cd1c8 FOREIGN KEY (point_id) REFERENCES public.points(id) ON DELETE CASCADE;


--
-- Name: solid_queue_blocked_executions fk_rails_4cd34e2228; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions
    ADD CONSTRAINT fk_rails_4cd34e2228 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: api_tokens fk_rails_4d2f9218d7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_tokens
    ADD CONSTRAINT fk_rails_4d2f9218d7 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: reading_rollups fk_rails_4e44c42ca7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_rollups
    ADD CONSTRAINT fk_rails_4e44c42ca7 FOREIGN KEY (point_id) REFERENCES public.points(id) ON DELETE CASCADE;


--
-- Name: ai_calls fk_rails_4e48191c3d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_calls
    ADD CONSTRAINT fk_rails_4e48191c3d FOREIGN KEY (automation_id) REFERENCES public.automations(id) ON DELETE SET NULL;


--
-- Name: sites fk_rails_51c02b70d3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT fk_rails_51c02b70d3 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: taggings fk_rails_51de8abb84; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT fk_rails_51de8abb84 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: shadow_actions fk_rails_547b292d40; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shadow_actions
    ADD CONSTRAINT fk_rails_547b292d40 FOREIGN KEY (automation_run_id) REFERENCES public.automation_runs(id) ON DELETE SET NULL;


--
-- Name: ai_usages fk_rails_57ac1b3dfd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usages
    ADD CONSTRAINT fk_rails_57ac1b3dfd FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: alerts fk_rails_61df1056f3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT fk_rails_61df1056f3 FOREIGN KEY (acked_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: events fk_rails_6844d4946c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_6844d4946c FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: shadow_actions fk_rails_6a2ac2786f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shadow_actions
    ADD CONSTRAINT fk_rails_6a2ac2786f FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: shadow_actions fk_rails_6aeffa9450; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shadow_actions
    ADD CONSTRAINT fk_rails_6aeffa9450 FOREIGN KEY (automation_id) REFERENCES public.automations(id) ON DELETE CASCADE;


--
-- Name: areas fk_rails_6c40205274; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas
    ADD CONSTRAINT fk_rails_6c40205274 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: alert_rules fk_rails_6da1190cf0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_rules
    ADD CONSTRAINT fk_rails_6da1190cf0 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: site_memberships fk_rails_6e07c54368; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_memberships
    ADD CONSTRAINT fk_rails_6e07c54368 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: point_links fk_rails_734958d827; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.point_links
    ADD CONSTRAINT fk_rails_734958d827 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: alerts fk_rails_7814415382; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT fk_rails_7814415382 FOREIGN KEY (alert_rule_id) REFERENCES public.alert_rules(id) ON DELETE CASCADE;


--
-- Name: points fk_rails_7abb1055ae; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.points
    ADD CONSTRAINT fk_rails_7abb1055ae FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: shadow_reports fk_rails_7b3f8030a1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shadow_reports
    ADD CONSTRAINT fk_rails_7b3f8030a1 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: solid_queue_batch_executions fk_rails_7c5e073422; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions
    ADD CONSTRAINT fk_rails_7c5e073422 FOREIGN KEY (batch_id) REFERENCES public.solid_queue_batches(id) ON DELETE CASCADE;


--
-- Name: notifications fk_rails_7c99fe0556; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_7c99fe0556 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: shadow_reports fk_rails_7ea55c4528; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shadow_reports
    ADD CONSTRAINT fk_rails_7ea55c4528 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: alerts fk_rails_80074b944a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT fk_rails_80074b944a FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: automations fk_rails_80f17165a8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automations
    ADD CONSTRAINT fk_rails_80f17165a8 FOREIGN KEY (blueprint_id) REFERENCES public.blueprints(id) ON DELETE SET NULL;


--
-- Name: solid_queue_ready_executions fk_rails_81fcbd66af; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions
    ADD CONSTRAINT fk_rails_81fcbd66af FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: automation_versions fk_rails_835446d9e5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_versions
    ADD CONSTRAINT fk_rails_835446d9e5 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: packages fk_rails_85441767fa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT fk_rails_85441767fa FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: notify_rules fk_rails_86a65c9929; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notify_rules
    ADD CONSTRAINT fk_rails_86a65c9929 FOREIGN KEY (point_id) REFERENCES public.points(id) ON DELETE CASCADE;


--
-- Name: dashboard_versions fk_rails_8887c3671f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dashboard_versions
    ADD CONSTRAINT fk_rails_8887c3671f FOREIGN KEY (author_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: dataset_records fk_rails_8b57992fe9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dataset_records
    ADD CONSTRAINT fk_rails_8b57992fe9 FOREIGN KEY (dataset_id) REFERENCES public.datasets(id) ON DELETE CASCADE;


--
-- Name: dashboard_versions fk_rails_8f81451b79; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dashboard_versions
    ADD CONSTRAINT fk_rails_8f81451b79 FOREIGN KEY (dashboard_id) REFERENCES public.dashboards(id) ON DELETE CASCADE;


--
-- Name: subscriptions fk_rails_933bdff476; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT fk_rails_933bdff476 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: alerts fk_rails_965d7a3df8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT fk_rails_965d7a3df8 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: tags fk_rails_967956ac97; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT fk_rails_967956ac97 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: events fk_rails_96df08af7b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_96df08af7b FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: active_storage_variant_records fk_rails_993965df05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_993965df05 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: solid_queue_claimed_executions fk_rails_9cfe4d4944; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions
    ADD CONSTRAINT fk_rails_9cfe4d4944 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: taggings fk_rails_9fcd2e236b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT fk_rails_9fcd2e236b FOREIGN KEY (tag_id) REFERENCES public.tags(id) ON DELETE CASCADE;


--
-- Name: scenes fk_rails_a0f7192e82; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scenes
    ADD CONSTRAINT fk_rails_a0f7192e82 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: points fk_rails_a4e1ac986e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.points
    ADD CONSTRAINT fk_rails_a4e1ac986e FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: invites fk_rails_aa8931b25d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT fk_rails_aa8931b25d FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: schedules fk_rails_ab7cc5b87d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedules
    ADD CONSTRAINT fk_rails_ab7cc5b87d FOREIGN KEY (scene_id) REFERENCES public.scenes(id) ON DELETE CASCADE;


--
-- Name: notifications fk_rails_b080fb4855; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_b080fb4855 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: external_refs fk_rails_b116eaa15e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_refs
    ADD CONSTRAINT fk_rails_b116eaa15e FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: devices fk_rails_b386e7e412; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT fk_rails_b386e7e412 FOREIGN KEY (integration_id) REFERENCES public.integrations(id) ON DELETE SET NULL;


--
-- Name: point_links fk_rails_b42977bcc7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.point_links
    ADD CONSTRAINT fk_rails_b42977bcc7 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: invites fk_rails_b52eeab183; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT fk_rails_b52eeab183 FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: integrations fk_rails_b5896051eb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integrations
    ADD CONSTRAINT fk_rails_b5896051eb FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: automations fk_rails_b84450b916; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automations
    ADD CONSTRAINT fk_rails_b84450b916 FOREIGN KEY (area_id) REFERENCES public.areas(id) ON DELETE SET NULL;


--
-- Name: solid_queue_batch_executions fk_rails_bc9f981155; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions
    ADD CONSTRAINT fk_rails_bc9f981155 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: active_storage_attachments fk_rails_c3b3935057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_c3b3935057 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: solid_queue_scheduled_executions fk_rails_c4316f352d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions
    ADD CONSTRAINT fk_rails_c4316f352d FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: ai_calls fk_rails_c634de66b8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_calls
    ADD CONSTRAINT fk_rails_c634de66b8 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: dashboard_versions fk_rails_cc7233754b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dashboard_versions
    ADD CONSTRAINT fk_rails_cc7233754b FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: ai_calls fk_rails_cd950a6025; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_calls
    ADD CONSTRAINT fk_rails_cd950a6025 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE SET NULL;


--
-- Name: datasets fk_rails_cf1a97a02e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.datasets
    ADD CONSTRAINT fk_rails_cf1a97a02e FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: integrations fk_rails_d329ca1b17; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integrations
    ADD CONSTRAINT fk_rails_d329ca1b17 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: devices fk_rails_d5b7012cbc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT fk_rails_d5b7012cbc FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: site_memberships fk_rails_d5c89f1c3c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_memberships
    ADD CONSTRAINT fk_rails_d5c89f1c3c FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: areas fk_rails_d65f3ff233; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas
    ADD CONSTRAINT fk_rails_d65f3ff233 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: points fk_rails_d6f3cdbe9a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.points
    ADD CONSTRAINT fk_rails_d6f3cdbe9a FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE;


--
-- Name: automation_runs fk_rails_d766b3bf6e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_runs
    ADD CONSTRAINT fk_rails_d766b3bf6e FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: points fk_rails_d7a2e829a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.points
    ADD CONSTRAINT fk_rails_d7a2e829a4 FOREIGN KEY (area_id) REFERENCES public.areas(id) ON DELETE SET NULL;


--
-- Name: dashboards fk_rails_dfb03225cd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dashboards
    ADD CONSTRAINT fk_rails_dfb03225cd FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: point_links fk_rails_dfc33b5548; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.point_links
    ADD CONSTRAINT fk_rails_dfc33b5548 FOREIGN KEY (target_point_id) REFERENCES public.points(id) ON DELETE CASCADE;


--
-- Name: areas fk_rails_e17994ac11; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas
    ADD CONSTRAINT fk_rails_e17994ac11 FOREIGN KEY (parent_id) REFERENCES public.areas(id) ON DELETE SET NULL;


--
-- Name: alert_rules fk_rails_e82824b3ed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_rules
    ADD CONSTRAINT fk_rails_e82824b3ed FOREIGN KEY (point_id) REFERENCES public.points(id) ON DELETE CASCADE;


--
-- Name: device_tokens fk_rails_e99e290457; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tokens
    ADD CONSTRAINT fk_rails_e99e290457 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: dashboards fk_rails_ea67961578; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dashboards
    ADD CONSTRAINT fk_rails_ea67961578 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: commands fk_rails_ead6accc90; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands
    ADD CONSTRAINT fk_rails_ead6accc90 FOREIGN KEY (automation_run_id) REFERENCES public.automation_runs(id) ON DELETE SET NULL;


--
-- Name: api_tokens fk_rails_f16b5e0447; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_tokens
    ADD CONSTRAINT fk_rails_f16b5e0447 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: notify_rules fk_rails_f2621aff5a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notify_rules
    ADD CONSTRAINT fk_rails_f2621aff5a FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: packages fk_rails_f6e97f226b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT fk_rails_f6e97f226b FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: audit_events fk_rails_fcd253d0d8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_fcd253d0d8 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: shadow_actions fk_rails_fd49348436; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shadow_actions
    ADD CONSTRAINT fk_rails_fd49348436 FOREIGN KEY (scene_id) REFERENCES public.scenes(id) ON DELETE CASCADE;


--
-- Name: automation_runs fk_rails_fda4d9d75d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_runs
    ADD CONSTRAINT fk_rails_fda4d9d75d FOREIGN KEY (cause_run_id) REFERENCES public.automation_runs(id) ON DELETE SET NULL;


--
-- Name: automation_runs fk_rails_feb0b29ea9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_runs
    ADD CONSTRAINT fk_rails_feb0b29ea9 FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: readings readings_point_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.readings
    ADD CONSTRAINT readings_point_id_fkey FOREIGN KEY (point_id) REFERENCES public.points(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261101130003'),
('20261101000001'),
('20261031190001'),
('20261031170001'),
('20261031160001'),
('20261031050002'),
('20261031050001'),
('20261031000001'),
('20261030300001'),
('20261030200001'),
('20261030100003'),
('20261030100002'),
('20261030100001'),
('20261029500001'),
('20261029400001'),
('20261029300001'),
('20261029200001'),
('20261029100002'),
('20261029100001'),
('20261029000001'),
('20261010000003'),
('20261010000002'),
('20261010000001');


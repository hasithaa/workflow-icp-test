-- The init scripts run as the superuser, so hand the objects to icp_user afterwards.
-- (User credentials live in their own database — see 10-icp-schema.sh.)
GRANT USAGE, CREATE ON SCHEMA public TO icp_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO icp_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO icp_user;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO icp_user;

-- Anything the server creates later belongs to it too.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO icp_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO icp_user;

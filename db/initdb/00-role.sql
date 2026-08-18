-- The ICP's own database role. Created before the schema so ownership and grants land on
-- the right principal.
CREATE ROLE icp_user WITH LOGIN PASSWORD 'icp_password';

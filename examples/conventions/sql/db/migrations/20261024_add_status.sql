-- up
ALTER TABLE shipments ADD COLUMN status text NOT NULL DEFAULT 'pending';
CREATE INDEX CONCURRENTLY index_shipments_on_status ON shipments (status);

-- down
DROP INDEX CONCURRENTLY index_shipments_on_status;
ALTER TABLE shipments DROP COLUMN status;

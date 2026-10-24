-- up
ALTER TABLE shipments ADD COLUMN carrier_id bigint NOT NULL;
CREATE INDEX index_shipments_on_carrier_id ON shipments (carrier_id);

---
paths: ["db/migrations/*.sql"]
scope: file
---
# Postgres migrations

Migrations run against live tables with traffic on them.

- **Indexes are built concurrently.** `CREATE INDEX` on an existing table
  uses `CONCURRENTLY`, so it doesn't block writes.

  Bad:

  ```sql
  CREATE INDEX index_orders_on_customer_id ON orders (customer_id);
  ```

  Good:

  ```sql
  CREATE INDEX CONCURRENTLY index_orders_on_customer_id ON orders (customer_id);
  ```

- **New columns on existing tables are nullable or have a default.** Adding a
  `NOT NULL` column with no default fails on a table that already has rows.

  Bad:

  ```sql
  ALTER TABLE orders ADD COLUMN currency text NOT NULL;
  ```

  Good:

  ```sql
  ALTER TABLE orders ADD COLUMN currency text NOT NULL DEFAULT 'USD';
  ```

- **Every migration can be undone.** A migration has a `-- down` section that
  reverses what its `-- up` section does.

  Bad:

  ```sql
  -- up
  ALTER TABLE orders ADD COLUMN notes text;
  ```

  Good:

  ```sql
  -- up
  ALTER TABLE orders ADD COLUMN notes text;

  -- down
  ALTER TABLE orders DROP COLUMN notes;
  ```

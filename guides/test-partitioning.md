# Test Partitioning

Tests run in parallel partitions (default: 3). Each partition uses its own database.

```bash
check --partitions 4  # Run with 4 partitions
```

## Database setup

Each partition needs its own database to avoid deadlocks and connection limit issues.
In `config/runtime.exs`, use `MIX_TEST_PARTITION` to create per-partition database URLs:

```elixir
# config/runtime.exs
partition = System.get_env("MIX_TEST_PARTITION", "")
test_database_url = System.get_env("TEST_DATABASE_URL")
test_database_url = test_database_url <> partition

config :my_app, MyApp.Repo, url: test_database_url
```

This creates databases like `my_app_test1`, `my_app_test2`, etc.

## Avoiding DB connection limits

With N partitions, your database needs at least `N * pool_size` connections.
Increase `max_connections` in PostgreSQL if you see connection errors:

```bash
# PostgreSQL config (or docker run command)
postgres -c max_connections=400 -c shared_buffers=2GB
```

Consider reducing `pool_size` per partition in `config/test.exs`:

```elixir
config :my_app, MyApp.Repo, pool_size: 10
```

With 3 partitions and pool_size 10, you need at least 30 connections.

## Scheduler tuning

AlCheck automatically limits BEAM schedulers per partition to avoid CPU contention:
`schedulers_online / partitions`. With 10 cores and 3 partitions, each gets ~3 schedulers.

## Partition capping

If `--dir` points to a directory with fewer test files than the partition count,
AlCheck automatically caps partitions to the file count and warns:

```
Not enough test files for 3 partitions (found 1), using 1
```

## Managing partition databases

Set up or drop databases for all partitions in parallel:

```bash
check --setup-db                  # mix ecto.setup for each partition
check --drop-db                   # mix ecto.drop for each partition
check --for-partitions 'mix ecto.reset'   # any command across partitions
```

See [Workflows](workflows.md) for details.

## Further reading

- [Running tests in partitions](https://klemens.blog/blog/tests-in-partitions/) - background behind this approach.

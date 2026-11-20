# LynxDB

[LynxDB](https://github.com/lynxbase/lynxdb) is a log store with a PPL query language. It
has no release build of every commit, so `install` builds it from source: `LYNXDB_REPO`
(default `https://github.com/lynxbase/lynxdb`) at `LYNXDB_REF` (a branch, tag or commit,
default `main`), with Go 1.26 or later from the path or the official Go tarball. The
commit that was built is the version of the result.

## Settings

`lynxdb.yaml` holds four settings that the dataset or the method need, and the order of
the rows:

- `retention: 0s` keeps all events; the default keeps seven days, and the events are from
  2024.
- `storage.time_fields: [time_us]` takes the event time from `time_us`, as VictoriaLogs
  is told with `_time_field=time_us`; none of the default time fields is in the data.
- `ingest.max_body_size: 1gb` lets one request carry one file (about 480 MB), as for
  VictoriaLogs; the default is 100 MB.
- `query.sync_timeout: 1h`: by default a query that runs longer than 30 seconds is
  answered with `202` and a job handle. VictoriaLogs gets `-search.maxQueryDuration=5m`
  for the same reason.
- `storage.sort_key: [kind, commit.operation, commit.collection, did]` orders the rows
  of every part by these fields, and by time within them. It is the physical design of
  this entry, as `ORDER BY` is for ClickHouse (the same fields, then the time) and
  `_stream_fields` for VictoriaLogs.

## Load

Up to 16 files are loaded at once, each with one request to `/api/v1/ingest` with the
file decompressed by `gzip -dc`, and a failed request fails the load. VictoriaLogs loads
8 at once. For LynxDB (commit b47cac79, m6i.8xlarge), 16 loaded 100m in 39.4 s against
48.9 s with 8, and 32 took 38.4 s; sending the `.json.gz` files as they are with
`Content-Encoding: gzip` was as fast at 16 and 32 and spent 40% more CPU of the server.
`load.log` has the response of every file.

After the files, a request for the stats writes the buffered events to disk, and the load
checks that the index holds every accepted event. Then it merges the index
(`POST /api/v1/indexes/bluesky/compact`, which returns when the merge is done), as the
loads of Elasticsearch and OpenSearch end with a force merge: the merge is a part of the
load time, and the queries run with no merge in flight. With a build that has no compact
request, the load waits until the part count and the size of the data directory have not
changed for `LYNXDB_MERGE_QUIET` seconds (default 10). `LYNXDB_LOAD_WAIT_MERGES=no` leaves
the merges to the background, as for VictoriaLogs and ClickHouse, for comparison.

The lines that are not JSON objects (a few documents longer than 64 KiB are split into
two lines in the dataset: 6 lines in 10m, 32 in 100m) are kept as events with only `_raw`
and the time of arrival. ClickHouse and VictoriaLogs reject them, so LynxDB counts
10,000,000 documents on 10m where they count 9,999,994, and 100,000,000 on 100m where they
count 99,999,968. In Q1 the row of the events without `commit.collection` is larger by
the same number; the other answers are the same as ClickHouse's.

## Start

LynxDB reads its own executable into the page cache before it listens, so `check` passes
only after that, and the first query after a restart does not fault in the code of the
server from the volume. It reads no data then. The ClickHouse entry loads its primary
keys at startup for the same reason.

## Queries

`queries.ppl` has the semantics of `../clickhouse/queries.sql`: `distinct_count` is exact,
as `uniqExact`, and `hour(_time)` is the hour in UTC. ClickHouse's
`date_diff('milliseconds', a, b)` counts the millisecond boundaries between `a` and `b`,
and `timestampdiff(MILLISECOND, a, b)` the whole milliseconds from `a` to `b`, so Q5 takes
the difference of the two times in whole milliseconds since the epoch.

The runtime is the wall-clock time of the HTTP request, as for VictoriaLogs. `query`
also prints the server's own time (`took_ms` of the response) to stderr as
`server_seconds`.

## Size and structure

`data-size` is the size of the files of the index on disk (`du -sb`): the parts, with
their token filters, and the manifest. It also prints the size of the parts from
`/api/v1/stats` to stderr; the two differ by the manifest, a few hundred bytes.

`retains_structure` is `no`: nested objects are stored as columns named by their dotted
paths and come back that way, so `{"a": {"b": 1}}` and `{"a.b": 1}` cannot be told apart.
Arrays, empty objects and nulls are kept.

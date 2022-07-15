-- for crosstab

create extension if not exists tablefunc;

-- drop all
drop table if exists tbl_yb_tserver_metrics_snapshots cascade;
drop function if exists fn_yb_tserver_metrics_snap;
drop view if exists vw_yb_tserver_metrics_snapshot_tablets;
drop view if exists vw_yb_tserver_metrics_report;
drop view if exists vw_yb_tserver_metrics_snapshot_tablets_metrics;
drop view if exists vw_yb_tserver_metrics_snap_and_show_tablet_load;
drop function if exists fn_yb_tserver_metrics_snap_and_show_tablet_load_ct;
drop view if exists vw_yb_tserver_metrics_snap_and_show_tablet_load;
drop function if exists fn_yb_tserver_metrics_snap_table;
drop view if exists vw_yb_tserver_metrics_snapshot_tablets_metrics;

-- create
create table if not exists tbl_yb_tserver_metrics_snapshots(
    host text default '',
    ts timestamptz default now(), 
    metrics json);

-- modify to yb_tserver_webport flag, 8200
-- default is 9000, but there is a conflict for the ipykernel_launcher
-- create or replace function fn_test()

create or replace function fn_yb_tserver_metrics_snap(snaps_to_keep int default 1,yb_tserver_webport int default 8200) 
returns timestamptz as $DO$
declare i record; 
begin
    delete from tbl_yb_tserver_metrics_snapshots 
    where 1=1
    and ts not in (
        select distinct ts          
        from tbl_yb_tserver_metrics_snapshots
        order by ts desc
        limit snaps_to_keep);

    for i in (select host from yb_servers()) loop 
         execute format('DROP TABLE if exists tbl_temp');
         execute format('CREATE TEMPORARY TABLE if not exists tbl_temp (host text default ''%s'', metrics jsonb)',i.host);
         execute format('copy tbl_temp(metrics) from program  ''curl -s http://%s:%s/metrics | jq -c '''' .[] | select(.attributes.namespace_name=="db_ybu" and .type=="tablet") | {type: .type, namespace_name: .attributes.namespace_name, tablet_id: .id, table_name: .attributes.table_name, table_id: .attributes.table_id, namespace_name: .attributes.namespace_name, metrics: .metrics[] | select(.name == ("rows_inserted","rocksdb_number_db_seek","rocksdb_number_db_next","is_raft_leader") ) } '''' ''',i.host,'8200'); 
        insert into tbl_yb_tserver_metrics_snapshots (host, metrics) select host, metrics from tbl_temp;
        execute format('DROP TABLE if exists tbl_temp');

    end loop; 

    return clock_timestamp(); 
end; 
$DO$ language plpgsql;

-- select * from vw_yb_tserver_metrics_snapshot_tablets;

create or replace view vw_yb_tserver_metrics_snapshot_tablets as
select 
    host
    , ts
    , (metrics ->> 'type') as type
    , (metrics ->> 'tablet_id') as tablet_id 
    , (metrics ->> 'namespace_name') as namespace_name
    , (metrics ->> 'table_name') as table_name 
    , (metrics ->> 'table_id') as table_id 
    , (metrics -> 'metrics' ->> 'name') as metric_name
    , (metrics -> 'metrics' ->> 'value')::numeric as metric_value
    from tbl_yb_tserver_metrics_snapshots;
    



-- drop view if exists vw_yb_tserver_metrics_snapshot_tablets_metrics;

create or replace view vw_yb_tserver_metrics_snapshot_tablets_metrics as
select
    ts
    , host
    , metric_name
    , namespace_name
    , table_name
    , table_id
    , tablet_id
    , sum(case when metric_name='is_raft_leader' then metric_value end)over(partition by host, namespace_name, table_name, table_id, tablet_id, ts) as is_raft_leader
    , metric_value-lead(metric_value)
        over(
            partition by 
            host, namespace_name, table_name, table_id, tablet_id, metric_name 
            order by ts desc) as value
    , extract(epoch from ts-lead(ts)
        over(
            partition by 
            host, namespace_name, table_name, table_id, tablet_id, metric_name 
            order by ts desc)) as seconds
    , rank()over(
        partition by
        host, namespace_name, table_name, table_id,tablet_id, metric_name 
        order by ts desc) as relative_snap_id
   , metric_value
   -- , metric_sum
   -- , metric_count
    from vw_yb_tserver_metrics_snapshot_tablets
    where 1=1 
    and table_name not in('tbl_yb_tserver_metrics_snapshots')
   -- and namespace_name <> 'system'
    and namespace_name IS NOT NULL;

-- select * from vw_yb_tserver_metrics_snapshot_tablets_metrics;


create or replace view vw_yb_tserver_metrics_report as
select 
    value
    , round(value/seconds) as rate
    , host
    , namespace_name
    , table_name
    , table_id
    , tablet_id
    , is_raft_leader
    , metric_name
    , ts
    , relative_snap_id
from vw_yb_tserver_metrics_snapshot_tablets_metrics as tablets_delta 
where 1=1
and table_id IS NOT NULL
and value>0;
--order by namespace_name,table_name,table_id,tablet_id;

-- select * from vw_yb_tserver_metrics_report;

-- a convenient "ybwr_last" shows the last snapshot:

create or replace view vw_yb_tserver_metrics_last as 
select * 
from vw_yb_tserver_metrics_report 
where 1=1
and relative_snap_id=1;


-- a convenient "ybwr_snap_and_show_tablet_load" takes a snapshot and show the metrics

create or replace view vw_yb_tserver_metrics_snap_and_show_tablet_load as 
select 
    value
    , rate
    , namespace_name
    , table_name
    , table_id
    , host
    , tablet_id
    , is_raft_leader
    , metric_name
    , to_char(100*value/sum(value)
        over(
            partition by
            namespace_name, table_name, table_id, metric_name),'999%') as "%table"
    , sum(value)
        over(
            partition by
            namespace_name, table_name, table_id, metric_name) as "table"
from vw_yb_tserver_metrics_last , fn_yb_tserver_metrics_snap()
where 1=1
and table_name not in ('tbl_yb_tserver_metrics_snapshots')
order by ts desc, namespace_name, table_name, table_id, host, tablet_id, is_raft_leader, "table" desc, value desc, metric_name;

-- select * from vw_yb_tserver_metrics_snap_and_show_tablet_load;



-- crosstab view

create or replace view vw_yb_tserver_metrics_snap_and_show_tablet_load_ct as 
select 
   ct_row_name
    , "ct_rocksdb_number_db_seek"
    , "ct_rocksdb_number_db_next"
    , "ct_rows_inserted"
     from crosstab($$
        select 
            format('%s | %s | %s | %s | %s', namespace_name, table_name, format('http://%s:7000/table?id=%s',host,table_id),tablet_id, case is_raft_leader when 0 then ' ' else 'L' end) vw_row_name, 
            metric_name category, 
            sum(value)
        from vw_yb_tserver_metrics_snap_and_show_tablet_load 
        where 1=1
        and metric_name in ('rocksdb_number_db_seek','rocksdb_number_db_next','rows_inserted') 
        group by namespace_name, table_name, host, table_id, tablet_id, is_raft_leader, metric_name
        order by 1, 2 desc,3
        $$) 
     as (ct_row_name text, "ct_rocksdb_number_db_seek" numeric, "ct_rocksdb_number_db_next" numeric, "ct_rows_inserted" decimal);


-- crosstab function

create or replace function fn_yb_tserver_metrics_snap_and_show_tablet_load_ct(isLocal int default 0)
returns table (
    row_name text, 
    rocksdb_number_db_seek numeric,
    rocksdb_number_db_next numeric,
    rows_inserted numeric
)
language plpgsql
as $DO$
begin

    if isLocal = 1 then
        return query
        select 
        ct_row_name
        , "ct_rocksdb_number_db_seek"
        , "ct_rocksdb_number_db_next"
        , "ct_rows_inserted"
        from crosstab($$
            select 
                format('%s | %s | %s | %s | %s', namespace_name, table_name, format('http://%s:7000/table?id=%s',host,table_id),tablet_id, case is_raft_leader when 0 then ' ' else 'L' end) vw_row_name, 
                metric_name category, 
                sum(value)
            from vw_yb_tserver_metrics_snap_and_show_tablet_load 
            where 1=1
            and metric_name in ('rocksdb_number_db_seek','rocksdb_number_db_next','rows_inserted') 
            group by namespace_name, table_name, host, table_id, tablet_id, is_raft_leader, metric_name
            order by 1, 2 desc,3
            $$) 
        as (ct_row_name text, "ct_rocksdb_number_db_seek" numeric, "ct_rocksdb_number_db_next" numeric, "ct_rows_inserted" decimal);
     else
        return query
        select 
            ct_row_name
            , "ct_rocksdb_number_db_seek"
            , "ct_rocksdb_number_db_next"
            , "ct_rows_inserted"
            from crosstab($$
                select 
                    format('%s | %s | %s | %s | %s', namespace_name, table_name, table_id, tablet_id, case is_raft_leader when 0 then ' ' else 'L' end) vw_row_name, 
                    metric_name category, 
                    sum(value)
                from vw_yb_tserver_metrics_snap_and_show_tablet_load 
                where 1=1
                and metric_name in ('rocksdb_number_db_seek','rocksdb_number_db_next','rows_inserted') 
                group by namespace_name, table_name, host, table_id, tablet_id, is_raft_leader, metric_name
                order by 1, 2 desc,3
                $$) 
            as (ct_row_name text, "ct_rocksdb_number_db_seek" numeric, "ct_rocksdb_number_db_next" numeric, "ct_rows_inserted" decimal);
     end if;
end; $DO$;






create or replace function fn_yb_tserver_metrics_snap_table(isLocal int default 0)
returns table (
    row_name text, 
    rocksdb_number_db_seek numeric,
    rocksdb_number_db_next numeric,
    rows_inserted numeric
)
language plpgsql
as $DO$
begin
    return query
    select * 
    from fn_yb_tserver_metrics_snap_and_show_tablet_load_ct(isLocal);
end; $DO$;



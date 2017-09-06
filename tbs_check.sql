-- ===============================================-=-=-
-- Softtek Confidential
-- 
-- Disclaimer
-- The contents of this document are property
-- of Softtek, and are for internal use only.
-- Any reproduction in whole or in part is strictly
-- prohibited without the written permission
-- of Softtek®. This document is subject to
-- change. Comments, corrections or questions
-- should be directed to the author.
-- 
-- ===============================================-=-=-

--@?\fig\tbs_check.sql
--host del @?\fig\logs\tbs_check.out
--spool @?\fig\logs\tbs_check.out
set echo off
set feedback off
set timing off
set time off
set lines 1000
set pages 100
set define on
set heading on
set verify off
undefine tablespace
undefine inc#
col TABLESPACE_NAME format a20  
col FILE_NAME format a60 
col ddl_resize format a105
select * from
(select ts.tablespace_name,to_char(ts.tam_Gb,'999,990.99') || ' Gb' total_space,to_char(fs.free_Gb,'999,990.99') || ' Gb' free_space,to_char(ts.tam_Gb-fs.free_Gb,'999,990.99') || ' Gb' bussy_space,to_char(((ts.tam_Gb-fs.free_Gb)/ts.tam_Gb)*100,'990.99')||'%' "%Bussy" from 
(select tablespace_name,(((sum(bytes)/1024)/1024)/1024) tam_Gb
from dba_data_files
group by tablespace_name) ts,
(select tablespace_name,(((sum(bytes)/1024)/1024)/1024) free_Gb
from dba_free_space
group by tablespace_name) fs
where ts.tablespace_name=fs.tablespace_name
order by 4 desc)
where tablespace_name = '&&tablespace'
--where substr(trim("%Bussy"),1,2) >= 86
--and tablespace_name not like '%ARC%'
order by "%Bussy" desc;

--Datafiles
select file_name, to_char(((bytes/1024/1024)/1024),'999,990.99') "Gb",
  case when file_name like '+DATA%' then 'alter /*&&inc#*/ database datafile '''||file_name||''' resize xxG;'
else 'alter /*&&inc#*/ database '||(select name from v$database)||' datafile '''||file_name||''' resize xxG;'
  end ddl_resize
from dba_data_files
 where tablespace_name = '&tablespace'
 --and file_name like '%dwindex05t%'
order by file_name;
--spool off

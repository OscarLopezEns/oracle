#!/bin/ksh
PATH=$PATH:/usr/bin:/sbin:/usr/local/bin;export PATH
####################################################################################
# ENV Variables
####################################################################################
    DBA_BIN=`dirname $0`;                export DBA_BIN
  TIMESTAMP=`date '+%m-%d-%y.%H:%M:%S'`; export TIMESTAMP
   HOSTNAME=`hostname`;                  export HOSTNAME
   BASENAME=`basename $0 .sh`;           export BASENAME
    WORKDIR=`dirname $0`;                export WORKDIR
     OSNAME=`uname -s`;                  export OSNAME
if   [ -d /dbdump    -a ! -L /dbdump    ]
then
  LOG_DIR=/dbdump/log;    export LOG_DIR
elif [ -d /dbdumplog -a ! -L /dbdumplog ]
then
  LOG_DIR=/dbdumplog/log; export LOG_DIR
elif [ -L /dbdumplog ]
then
  LOG_DIR=/dbdumplog; export LOG_DIR
elif [ -L ${DBA_BIN}/dbdumplog ]
then
  LOG_DIR=${DBA_BIN}/dbdumplog; export LOG_DIR
else
  echo "\nERROR!!! LOG_DIR not found: /dbdump/log, /dbdumplog/log"
  exit 1
fi
echo "LOG_DIR: $LOG_DIR"
PROGRAM_CTL="${WORKDIR}/${BASENAME}.ctl";                             export PROGRAM_CTL
PROGRAM_OUT="${LOG_DIR}/${BASENAME}_`echo ${HOSTNAME}|cut -c5-`.out"; export PROGRAM_OUT
PROGRAM_LOG="${LOG_DIR}/${BASENAME}_${HOSTNAME}.log";                 export PROGRAM_LOG
PROGRAM_TMP="${LOG_DIR}/${BASENAME}_${HOSTNAME}.tmp";                 export PROGRAM_TMP

touch ${PROGRAM_LOG} > ${PROGRAM_TMP} 2>&1
if [ $? -ne 0 ]
then
  echo "\nERROR: Cannot create file ${PROGRAM_LOG}, please fix the problem and try again"
  echo "       Command output:"
  (cat ${PROGRAM_TMP}; echo "\n")
  exit 2
fi

if [ $# -ne 6 ]
then
  echo "\nusage: $0 ORACLE_SID tbs_size STWT STAT BTWT BTAT"
  echo   "where:"
  echo   "       ORACLE_SID  Target database SID"
  echo   "       TBS_SIZE    Size Threshold"
  echo   "       STWT        Small Tablespace Warning Threshold"
  echo   "       STAT        Small Tablespace Alert Threshold"
  echo   "       BTWT        Big Tablespace Warning Threshold"
  echo   "       BTAT        Big Tablespace Alert Threshold"
  echo   "example:"
  echo   "       $0 AMIP1 40960 90 95 95 98"
  echo   "       $0 WEBP1 40960 90 95 95 98"
  echo   "       $0 OEMR1 40960 90 95 95 98\n"
  exit 3
fi

##########################################################################################
# To make sure /usr/local/bin/oraenv works properly when executed by a crontab job, a base
# configuration is required, /usr/local/bin/oraenv calls $ORACLE_HOME/bin/dbhome utility.
# Do not delete or move to another position of the script the following lines:
## Starts here
if [ "`uname -s`" = "Linux" ]
then
  ORATAB=/etc/oratab;            export ORATAB
else
  ORATAB=/var/opt/oracle/oratab; export ORATAB
fi
    ORACLE_BASE=/oracle/app/oracle;                  export ORACLE_BASE
    ORACLE_HOME=$ORACLE_BASE/product/10.2.0;         export ORACLE_HOME
LD_LIBRARY_PATH=/usr/openwin/lib:${ORACLE_HOME}/lib; export LD_LIBRARY_PATH
           PATH=${PATH}:${ORACLE_HOME}/bin:;         export PATH
     ORAENV_ASK=NO;                                  export ORAENV_ASK
     ORACLE_SID=$1;                                  export ORACLE_SID

if [ -z "`grep -v \"^#\" ${ORATAB}|grep -v \"^$\"|grep -v \"^*\" | grep $1`" ]
then
  echo "\n=========================================================================================="
  echo " ERROR!!! ${ORACLE_SID} INSTANCE HAS NOT A VALID OR ENABLED ENTRY IN ${ORATAB} FILE:"
  echo "=========================================================================================="
  cat ${ORATAB}
  echo "------------------------------------------------------------------------------------------\n"
  exit 2;
fi

. /usr/local/bin/oraenv > /dev/null 2>&1
## Ends here

####################################################################################
# ENV Variables
####################################################################################
TBS_SIZE=$2;  export TBS_SIZE
    STWT=$3;  export STWT
    STAT=$4;  export STAT
    BTWT=$5;  export BTWT
    BTAT=$6;  export BTAT
 TOP_PCT="?"; export TOP_PCT
# Overrides the default environment variables values
PROGRAM_OUT="${LOG_DIR}/${BASENAME}_`echo ${HOSTNAME}|cut -c5-`_${ORACLE_SID}.out"; export PROGRAM_OUT
PROGRAM_LOG="${LOG_DIR}/${BASENAME}_${HOSTNAME}_${ORACLE_SID}.log";                 export PROGRAM_LOG
PROGRAM_TMP="${LOG_DIR}/${BASENAME}_${HOSTNAME}_${ORACLE_SID}.tmp";                 export PROGRAM_TMP

####################################################################################
# Check for instance running (pmon process active)
####################################################################################
SID_RUNNING=`ps -eaf | grep ora_pmon_${ORACLE_SID} | grep -v grep | wc -l`
if [ ${SID_RUNNING} -ne 1 ]
then
  echo "\n=========================================================================================="
  echo " ERROR!!! ${ORACLE_SID} INSTANCE IS NOT RUNNING. "
  echo "==========================================================================================\n"
  exit 3;
fi

####################################################################################
# Find database name and hostname
####################################################################################
DB_INFO_LOG=${LOG_DIR}/${BASENAME}_${HOSTNAME}_${ORACLE_SID}_db_name.log
DB_INFO_OUT=${LOG_DIR}/${BASENAME}_${HOSTNAME}_${ORACLE_SID}_db_name.out
>${DB_INFO_OUT}
>${DB_INFO_LOG}
sqlplus -S "/ as sysdba" << EOF > ${DB_INFO_OUT} 2>&1
set echo      off
set pagesize    0
set linesize  120
set feedback  off
set trimspool  on
spool ${DB_INFO_LOG}
select name, open_mode from v\$database;
spool off
EOF

if [ -n "`grep \"ORA-\" ${DB_INFO_LOG}`" -o \
        "`cat ${DB_INFO_LOG}|awk '{print $2}'`" = "MOUNTED" ]
then
  echo "\n=========================================================================================="
  echo " ERROR!!! ${ORACLE_SID} INSTANCE IS NOT AVAILABLE. "
  echo "=========================================================================================="
  cat ${DB_INFO_LOG}
  echo "------------------------------------------------------------------------------------------\n"
  exit 4;
fi

DB_NAME=`cat ${DB_INFO_LOG}|awk '{print $1}'`
export DB_NAME

echo "\nAnalyzing ${DB_NAME}->${ORACLE_SID} ... "

>${PROGRAM_LOG}

####################################################################################
# Check for segments that won't be able to extend because of no free space
####################################################################################
DB_INFO_LOG=${LOG_DIR}/${BASENAME}_${HOSTNAME}_${ORACLE_SID}_next_extent.log
DB_INFO_OUT=${LOG_DIR}/${BASENAME}_${HOSTNAME}_${ORACLE_SID}_next_extent.out
>${DB_INFO_OUT}
>${DB_INFO_LOG}
echo "Checking for segments that won't be able to extend because of no free space ... \c"
sqlplus -S '/ as sysdba' << EOF > ${DB_INFO_OUT} 2>&1
set echo       off
set pagesize     0
set linesize   120
set feedback   off
set trimspool   on
col owner           format a12
col segment_name    format a30
col segment_type    format a16
col tablespace_name format a20
spool ${DB_INFO_LOG}
SELECT a.owner, a.segment_name, a.segment_type, a.tablespace_name
FROM dba_segments a
WHERE a.next_extent is not null
  and a.tablespace_name not like '%TEMP%'
  and a.tablespace_name not like '%UNDO%'
  and a.tablespace_name not like '%_ARC'
  and a.tablespace_name not like '%_PMDM'
  and a.tablespace_name not like 'TRDM_200%'
  and a.tablespace_name not in ('TRDM_2007_D_U32M',        'TRDM_IDX_U256K_PMDM',     'TRDM_U4M_PMDM',
                                'VISION_MD_2001_U32M_ARC', 'VISION_MD_2002_U32M_ARC', 'VISION_MD_2002_U4M_ARC',
                                'VISION_MD_2004_U32M_ARC', 'VISION_MD_2004_U4M_ARC',  'VISION_MD_2006_U32M_ARC',
                                'VISION_MD_2007_U32M_ARC','MINERVA_DATA_DYNAMIC_01','TRDM_2010_D_16K_U32M','TRDM_DATA_2007')
  and not exists (select 'X'
                  from sys.dba_free_space b
                  where a.tablespace_name = b.tablespace_name
                    and bytes >= next_extent)
UNION ALL
SELECT a.owner, a.segment_name, a.segment_type, a.tablespace_name
FROM   dba_segments a
WHERE a.next_extent is null
  and a.tablespace_name not like '%TEMP%'
  and a.tablespace_name not like '%UNDO%'
  and a.tablespace_name not like '%_ARC'
  and a.tablespace_name not like '%_PMDM'
  and a.tablespace_name not like 'TRDM_200%'
  and a.tablespace_name not in ('TRDM_2007_D_U32M',        'TRDM_IDX_U256K_PMDM',     'TRDM_U4M_PMDM',
                                'VISION_MD_2001_U32M_ARC', 'VISION_MD_2002_U32M_ARC', 'VISION_MD_2002_U4M_ARC',
                                'VISION_MD_2004_U32M_ARC', 'VISION_MD_2004_U4M_ARC',  'VISION_MD_2006_U32M_ARC',
                                'VISION_MD_2007_U32M_ARC','MINERVA_DATA_DYNAMIC_01','TRDM_2010_D_16K_U32M','TRDM_DATA_2007')
  and not exists (select 'X'
                  from sys.dba_free_space b
                  where a.tablespace_name = b.tablespace_name
                    and bytes >= get_next(extents));
spool off
EOF

if   [ ! -s ${DB_INFO_LOG} ]
then
  echo "OK"
elif [ -n "`grep 'ORA-' ${DB_INFO_LOG}`" ]
then
  echo "ERRORS FOUND!!!"
  echo "\nChecking for segments that won't be able to extend because of no free space ... ERRORS FOUND!!!" >> ${PROGRAM_LOG}
  cat ${DB_INFO_LOG}                                                                                       >> ${PROGRAM_LOG}
else
  echo "ITEMS FOUND!"
  echo "List of segments that won't be able to extend because of no free space" >> ${PROGRAM_LOG}
  echo "----------------------------------------------------------------------" >> ${PROGRAM_LOG}
  echo " "                                                                      >> ${PROGRAM_LOG}
  cat ${DB_INFO_LOG}                                                            >> ${PROGRAM_LOG}
fi

####################################################################################
# Check for segments that won't be able to extend because of maxextent reached
####################################################################################
DB_INFO_LOG=${LOG_DIR}/${BASENAME}_${HOSTNAME}_${ORACLE_SID}_max_extent.log
DB_INFO_OUT=${LOG_DIR}/${BASENAME}_${HOSTNAME}_${ORACLE_SID}_max_extent.out
>${DB_INFO_OUT}
>${DB_INFO_LOG}
echo "Checking for segments that won't be able to extend because of maxextent reached ... \c"
sqlplus -S '/ as sysdba' << EOF > ${DB_INFO_OUT} 2>&1
set echo       off
set pagesize     0
set linesize   120
set feedback   off
set trimspool   on
col owner           format a12
col segment_name    format a30
col segment_type    format a16
col tablespace_name format a20
spool ${DB_INFO_LOG}
SELECT owner, segment_name, segment_type, extents, max_extents, tablespace_name
FROM dba_segments
WHERE segment_type != 'CACHE'
  and extents >= (max_extents - 5);
spool off
EOF

if   [ ! -s ${DB_INFO_LOG} ]
then
  echo "OK"
elif [ -n "`grep 'ORA-' ${DB_INFO_LOG}`" ]
then
  echo "ERRORS FOUND!!!"
  echo "\nChecking for segments that won't be able to extend because of maxextent reached ... ERRORS FOUND!!!" >> ${PROGRAM_LOG}
  cat ${DB_INFO_LOG}                                                                                           >> ${PROGRAM_LOG}
else
  echo "ITEMS FOUND!"
  echo "List of segments that won't be able to extend because of maxextent reached" >> ${PROGRAM_LOG}
  echo "--------------------------------------------------------------------------" >> ${PROGRAM_LOG}
  echo " "                                                                          >> ${PROGRAM_LOG}
  cat ${DB_INFO_LOG}                                                                >> ${PROGRAM_LOG}
fi

####################################################################################
# Check for tablespaces above threshold of space utilization.
#  Tablespace size threshold                   : 40960 MB (40 GB)
#  Small tablespace usage threshold WARNING (%): 90
#  Small tablespace usage threshold ALERT (%)  : 95
#  Big tablespace usage threshold WARNING (%)  : 95
#  Big tablespace usage threshold ALERT (%)    : 98
####################################################################################
DB_INFO_LOG=${LOG_DIR}/${BASENAME}_${HOSTNAME}_${ORACLE_SID}_tbs_utilization.log
DB_INFO_OUT=${LOG_DIR}/${BASENAME}_${HOSTNAME}_${ORACLE_SID}_tbs_utilization.out
>${DB_INFO_OUT}
>${DB_INFO_LOG}
echo "Checking for tablespaces above threshold of space utilization ... \c"
sqlplus -S '/ as sysdba' << EOF > ${DB_INFO_OUT} 2>&1
set echo       off
set pagesize     0
set linesize   120
set feedback   off
set trimspool   on
set serveroutput on size 1000000
spool ${DB_INFO_LOG}
declare
  cursor C01 is
    select tbs, sum(total) total, sum(free) free, max(maximum) maximum, trunc(((sum(total)-sum(free))/decode(sum(total),0,1,sum(total)))*100,2) used
      from (select tablespace_name tbs, sum(bytes)/1024/1024  total, 0 free, 0 maximum
              from dba_data_files
              where tablespace_name not like '%TEMP%'
                and tablespace_name not like '%UNDO%'
                and tablespace_name not like '%_ARC'
                and tablespace_name not like '%_PMDM'
                and tablespace_name not like 'TRDM_200%'
                and tablespace_name not in ('TRDM_2007_D_U32M',        'TRDM_IDX_U256K_PMDM',     'TRDM_U4M_PMDM',
                                            'VISION_MD_2001_U32M_ARC', 'VISION_MD_2002_U32M_ARC', 'VISION_MD_2002_U4M_ARC',
                                            'VISION_MD_2004_U32M_ARC', 'VISION_MD_2004_U4M_ARC',  'VISION_MD_2006_U32M_ARC',
                                            'VISION_MD_2007_U32M_ARC','MINERVA_DATA_DYNAMIC_01','TRDM_2010_D_16K_U32M','TRDM_DATA_2007')
              group by tablespace_name
            UNION ALL
            select tablespace_name tbs, 0 total, sum(bytes)/1024/1024 free, max(bytes)/1024/1024 maximum
              from dba_free_space
              where tablespace_name not like '%TEMP%'
                and tablespace_name not like '%UNDO%'
                and tablespace_name not like '%_ARC'
                and tablespace_name not like '%_PMDM'
                and tablespace_name not like 'TRDM_200%'
                and tablespace_name not in ('TRDM_2007_D_U32M',        'TRDM_IDX_U256K_PMDM',     'TRDM_U4M_PMDM',
                                            'VISION_MD_2001_U32M_ARC', 'VISION_MD_2002_U32M_ARC', 'VISION_MD_2002_U4M_ARC',
                                            'VISION_MD_2004_U32M_ARC', 'VISION_MD_2004_U4M_ARC',  'VISION_MD_2006_U32M_ARC',
                                            'VISION_MD_2007_U32M_ARC','MINERVA_DATA_DYNAMIC_01','TRDM_2010_D_16K_U32M','TRDM_DATA_2007')
              group by tablespace_name)
   group by tbs
   order by 2 desc;
   tbs_size_threshold             number  := ${TBS_SIZE}; -- 40960 MB = 40 GB
   small_tbs_usage_warn_threshold number  := ${STWT};     -- 90
   small_tbs_usage_alrt_threshold number  := ${STAT};     -- 95
   big_tbs_usage_warn_threshold   number  := ${BTWT};     -- 95
   big_tbs_usage_alrt_threshold   number  := ${BTAT};     -- 98
   alert_type                     varchar2(8) := '????????';
begin
  for R01 in C01 loop
    if (((R01.total <  tbs_size_threshold) and ((R01.used >= small_tbs_usage_warn_threshold) or (R01.used >= small_tbs_usage_alrt_threshold))) or
        ((R01.total >= tbs_size_threshold) and ((R01.used >= big_tbs_usage_warn_threshold)   or (R01.used >= big_tbs_usage_alrt_threshold)))) then
      if    (((R01.total <  tbs_size_threshold) and (R01.used >= small_tbs_usage_alrt_threshold)) or
             ((R01.total >= tbs_size_threshold) and (R01.used >= big_tbs_usage_alrt_threshold))) then
        alert_type := 'ALERT!!!';
      elsif (((R01.total <  tbs_size_threshold) and (R01.used >= small_tbs_usage_warn_threshold)) or
             ((R01.total >= tbs_size_threshold) and (R01.used >= big_tbs_usage_warn_threshold))) then
        alert_type := 'WARNING!';
      end if;
      dbms_output.put_line(rpad(R01.tbs,26) || ' ' || lpad(trunc(R01.total,2),11)  || ' ' || lpad(trunc(R01.free,2),10)   || ' ' ||
                           lpad(trunc(R01.maximum,2),9) || ' ' || lpad(trunc(R01.used),6)      ||
                           ' % ' || alert_type);
    end if;
  end loop;
exception
  when others then
    dbms_output.put_line(sqlerrm);
end;
/
spool off
EOF

if   [ ! -s ${DB_INFO_LOG} ]
then
  echo "OK"
elif [ -n "`grep 'ORA-' ${DB_INFO_LOG}`" ]
then
  echo "ERRORS FOUND!!!"
  echo "\nChecking for tablespaces above threshold of space utilization ... ERRORS FOUND!!!" >> ${PROGRAM_LOG}
  cat ${DB_INFO_LOG}                                                                         >> ${PROGRAM_LOG}
else
  echo "ITEMS FOUND!"
  echo "List of tablespaces above threshold of space utilization"                      >> ${PROGRAM_LOG}
  echo "--------------------------------------------------------"                      >> ${PROGRAM_LOG}
  echo " "                                                                             >> ${PROGRAM_LOG}
  echo "TABLESPACE NAME            TOTAL SPACE FREE SPACE MAX SPACE PCT BUSY  LEVEL  " >> ${PROGRAM_LOG}
  echo "-------------------------- ----------- ---------- --------- -------- --------" >> ${PROGRAM_LOG}
  cat ${DB_INFO_LOG}                                                                   >> ${PROGRAM_LOG}
  TOP_PCT=`cat ${DB_INFO_LOG}|grep "%" | awk '{print $5}' | sort | uniq | tail -1`
fi

####################################################################################
# Inform of status.
####################################################################################
if [ -s ${PROGRAM_LOG} ]
then
  echo "Issues found, notifying status to DBA and IOM teams ... \c"
       MAIL_RECIPIENT="iaan-1@ge.com,ssga_ct_softtekdba@ssga.com"
#      MAIL_RECIPIENT="arturo.aranda@ge.com"
  MAIL_RETURN_ADDRESS=${MAIL_RECIPIENT}
  if     [ -n "`grep -i error  ${PROGRAM_LOG}`" ]
  then
    MAIL_SUBJECT="ERRORS FOUND!!! Potential space allocation shortage on ${ORACLE_SID}@`hostname`"
    echo "\nERRORS FOUND!!! Potential space allocation shortage on ${ORACLE_SID}@`hostname`" >> ${PROGRAM_LOG}
  elif   [ -n "`grep -i alert   ${PROGRAM_LOG}`" ]
  then
    MAIL_SUBJECT="ALERT!!! Potential space allocation shortage on ${ORACLE_SID}@`hostname`"
    echo "\nALERT!!! Potential space allocation shortage on ${ORACLE_SID}@`hostname`" >> ${PROGRAM_LOG}
  elif [ -n "`grep -i warning ${PROGRAM_LOG}`" ]
  then
    MAIL_SUBJECT="WARNING! Potential space allocation shortage on ${ORACLE_SID}@`hostname`"
    echo "\nWARNING! Potential space allocation shortage on ${ORACLE_SID}@`hostname`" >> ${PROGRAM_LOG}
  else
    MAIL_SUBJECT="???????? Potential space allocation shortage on ${ORACLE_SID}@`hostname`"
    echo "\n???????? Potential space allocation shortage on ${ORACLE_SID}@`hostname`" >> ${PROGRAM_LOG}
  fi
  echo "
(DB_Name)${DB_NAME}(/DB_Name)
(Percentage)${TOP_PCT}(/Percentage)" >> ${PROGRAM_LOG}
  if   [ ${OSNAME} = "SunOS" ]
  then
    cat ${PROGRAM_LOG} | mailx -s "${MAIL_SUBJECT}" -r "${MAIL_RETURN_ADDRESS}"  "${MAIL_RECIPIENT}"
  elif [ ${OSNAME} = "Linux" ]
  then
    cat ${PROGRAM_LOG} | mailx -s "${MAIL_SUBJECT}" "${MAIL_RECIPIENT}"
  else
    cat ${PROGRAM_LOG} | mailx -s "${MAIL_SUBJECT}" "${MAIL_RECIPIENT}"
  fi
  echo "Done."
else
  echo "Everything looks good!"
fi

echo "Analysis of ${DB_NAME}->${ORACLE_SID} Complete."

exit 0

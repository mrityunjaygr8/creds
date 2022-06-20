#!/usr/bin/env bash

# long args via getopts is taken from 
# https://stackoverflow.com/questions/402377/using-getopts-to-process-long-and-short-command-line-options
die() { echo "$*" >&2; exit 2; }  # complain to STDERR and exit with error
needs_arg() { if [ -z "$OPTARG" ]; then die "No arg for --$OPT option"; fi; }

while getopts i:o:-: OPT; do
  # support long options: https://stackoverflow.com/a/28466267/519360
  if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
    OPT="${OPTARG%%=*}"       # extract long option name
    OPTARG="${OPTARG#"$OPT"}"   # extract long option argument (may be empty)
    OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
  fi
  case "$OPT" in
    i | input-path )    needs_arg; input="$OPTARG" ;;
    o | output-path )  needs_arg; output="$OPTARG" ;;
    ??* )          die "Illegal option --$OPT" ;;  # bad long option
    ? )            exit 2 ;;  # bad short option (error reported via getopts)
  esac
done
shift $((OPTIND-1)) # remove parsed options and args from $@ list

set -eu -o pipefail
name=$(echo "$output" | sed 's/\//__/g' | sed 's/-/_/g')
OUTFILE="creds__${name}.txt"
declare -A DATA

rm -rf "$OUTFILE"

SSM_PARAMS=("DATABASE_HOST" "DATABASE_PORT" "DATABASE_MASTER_PASSWORD" "DATABASE_MASTER_USERNAME" "REDIS_HOST" "REDIS_PORT")
for x in "${SSM_PARAMS[@]}"
do
  d=$(aws ssm get-parameter --with-decryption --name "/$input/$x" | jq -r .Parameter.Value)
  DATA["$x"]="$d"
done


# echo "${DATA['DATABASE_HOST']}"
REDIS_NEXT_KEY='next_usable'
REDIS_BOOKKEEPING_DB=0

# requires redis-cli to be installed
# checking which will be the next key for the DB in redis
next_usable=$(redis-cli -h "${DATA['REDIS_HOST']}" -p "${DATA['REDIS_PORT']}" -n "$REDIS_BOOKKEEPING_DB" GET "$REDIS_NEXT_KEY")

if [[ -z $next_usable ]]
then
  next_usable=1
fi

if ! [[ $next_usable -ge 1 ]]
then
  echo "The Redis Next Key is not in correct format"
  echo "Halting, Please check manually"
  exit 1
fi

new_next_usable=$(echo "$next_usable" + "1" | bc)

declare -A OUT

OUT['DATABASE_NAME']="db__$name"
OUT['DATABASE_HOST']="${DATA['DATABASE_HOST']}"
OUT['DATABASE_PORT']="${DATA['DATABASE_PORT']}"
OUT['DATABASE_USER']="user__$name"
OUT['DATABASE_PASS']=$(echo $RANDOM | md5sum | head -c 20; echo;)
OUT['REDIS_HOST']="${DATA['REDIS_HOST']}"
OUT['REDIS_PORT']="${DATA['REDIS_PORT']}"
OUT['REDIS_DB']="$next_usable"



# Requires postgresql-client-common and postgresql-client-<target-version> to be installed

PGPASSWORD="${DATA['DATABASE_MASTER_PASSWORD']}" createdb -h "${DATA['DATABASE_HOST']}" -p "${DATA['DATABASE_PORT']}" -U "${DATA['DATABASE_MASTER_USERNAME']}" "${OUT['DATABASE_NAME']}"
PGPASSWORD="${DATA['DATABASE_MASTER_PASSWORD']}" createuser -h "${DATA['DATABASE_HOST']}" -p "${DATA['DATABASE_PORT']}" -U "${DATA['DATABASE_MASTER_USERNAME']}" "${OUT['DATABASE_USER']}"
PGPASSWORD="${DATA['DATABASE_MASTER_PASSWORD']}" psql -h "${DATA['DATABASE_HOST']}" -p "${DATA['DATABASE_PORT']}" -U "${DATA['DATABASE_MASTER_USERNAME']}" -c "ALTER USER ${OUT['DATABASE_USER']} WITH ENCRYPTED PASSWORD '${OUT['DATABASE_PASS']}'; GRANT ALL PRIVILEGES ON DATABASE ${OUT['DATABASE_NAME']} TO ${OUT['DATABASE_USER']};"

redis-cli -h "${DATA['REDIS_HOST']}" -p "${DATA['REDIS_PORT']}" -n "$REDIS_BOOKKEEPING_DB" SET "$REDIS_NEXT_KEY" "$new_next_usable"


for x in "${!OUT[@]}"; do
  echo "$x=${OUT[$x]}" >> "$OUTFILE"
  aws ssm put-parameter \
      --name "/$output/$x" \
      --value "${OUT[$x]}" \
      --type "SecureString"
done


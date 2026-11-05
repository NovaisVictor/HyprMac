#!/usr/bin/env bash
cd "$(dirname "$0")/.."
source ./script/setup.sh

out_file='./Sources/Common/cmdHelpGenerated.swift'

hyprmac_prefix="hyprmac"
____usage_prefix="   USAGE:"
_______or_prefix="      OR:"
____strip_prefix="   "

triple_quote='"""'

cat << EOF > $out_file
// FILE IS GENERATED FROM docs/hyprmac-*.adoc files
// TO REGENERATE THE FILE RUN generate.sh

EOF

for file in docs/hyprmac-*.adoc; do
    subcommand=$(basename "$file" | sed 's/^hyprmac-//' | sed 's/\.adoc$//' | sed 's/-/_/g')
    sed -n -E '/tag::synopsis/, /end::synopsis/ p' "$file" | \
        sed '1d' | \
        sed '$d' | \
        sed '/^$/ d' | \
        sed "1   s/^$hyprmac_prefix/$____usage_prefix/" | \
        sed "2,$ s/^$hyprmac_prefix/$_______or_prefix/" | \
        sed     "s/^$____strip_prefix//" | \
        sed "1 s/^/let ${subcommand}_help_generated = $triple_quote\n/" | \
        sed "\$ s/$/\n${triple_quote}/" | \
        sed '2,$ s/^/    /' >> $out_file
done

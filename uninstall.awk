# Everything else just converts easily (we don't bother with indexes here as
# they'll be dropped when the corresponding table is)
# Convert schema and role creation to DROPs with cascade which should ensure
# we remove everything (all other objects sit beneath schemas so a cascaded
# drop should take care of them)
/^CREATE +(SCHEMA|ROLE) +([A-Za-z0-9_#$@]+)\>/ {
	print "DROP " $2 " " gensub(";$$", "", 1, $3) " CASCADE;";
}

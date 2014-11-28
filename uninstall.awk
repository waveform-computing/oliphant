# Convert schema and role creation to DROPs with cascade which should ensure
# we remove everything (all other objects sit beneath schemas so a cascaded
# drop should take care of them)
/^CREATE SCHEMA +([A-Za-z0-9_]+)\>/ {
	print "DROP SCHEMA " gensub(";$$", "", 1, $3) " CASCADE;";
}

/^CREATE ROLE +([A-Za-z0-9_]+)\>/ {
	print "DROP ROLE " gensub(";$$", "", 1, $3) ";";
}

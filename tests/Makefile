ALL_TESTS:=test_assert.sql test_auth.sql test_history.sql test_merge.sql

test: test.sql
	psql -d $(DBNAME) -e -v ON_ERROR_STOP=1 -f $<

clean:
	rm -f test.sql

test.sql: $(ALL_TESTS)
	echo "\c $(DBNAME)" > $@
	echo "BEGIN;" >> $@
	echo "SET search_path TO $(SCHEMANAME), public;" >> $@
	cat $^ >> $@
	echo "ROLLBACK;" >> $@

.PHONY: test clean


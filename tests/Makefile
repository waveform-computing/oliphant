ALL_TESTS:=test_assert.sql

test: test.sql
	psql -d $(DBNAME) -f $<

clean:
	rm -f test.sql

test.sql: $(ALL_TESTS)
	echo "\c $(DBNAME)" > $@
	echo "BEGIN;" >> $@
	echo "SET search_path TO $(SCHEMANAME), public;" >> $@
	cat $^ >> $@
	echo "ROLLBACK;" >> $@

.PHONY: test clean


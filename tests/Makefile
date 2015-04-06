test: $(ALL_TESTS)
	psql -1 -d $(DBNAME) -e -v ON_ERROR_STOP=1 -f test_assert.sql
	psql -1 -d $(DBNAME) -e -v ON_ERROR_STOP=1 -f test_auth.sql
	psql -1 -d $(DBNAME) -e -v ON_ERROR_STOP=1 -f test_history.sql
	psql -1 -d $(DBNAME) -e -v ON_ERROR_STOP=1 -f test_merge.sql

.PHONY: test


DBNAME:=sample
SCHEMANAME:=utils

VERSION:=0.1
ALL_EXT:=
ALL_TESTS:=$(wildcard tests/*.sql)
ALL_SQL:=$(filter-out install.sql uninstall.sql,$(wildcard *.sql))
ALL_FOO:=$(ALL_SQL:%.sql=%.foo)

install: install.sql
	psql -f $<

uninstall: uninstall.sql
	psql -f $<

doc:
	$(MAKE) -C docs html

test:
	$(MAKE) -C tests test DBNAME=$(DBNAME) SCHEMANAME=$(SCHEMANAME)

clean: $(SUBDIRS)
	$(MAKE) -C docs clean
	$(MAKE) -C tests clean
	rm -f foo
	rm -f *.foo
	rm -f utils.sql
	rm -f install.sql
	rm -f uninstall.sql
	rm -fr build/ dist/

utils.sql: utils.sqt Makefile
	sed -e 's/%SCHEMANAME%/$(SCHEMANAME)/' $< > $@

%.foo: %.sql
	cat $< >> foo
	touch $@

install.sql: $(ALL_FOO)
	echo "\c $(DBNAME)" > $@
	echo "SET search_path TO $(SCHEMANAME), public;" >> $@
	echo "BEGIN;" >> $@
	cat foo >> $@
	echo "COMMIT;" >> $@
	rm foo
	rm -f *.foo

uninstall.sql: install.sql
	echo "\c $(DBNAME)" > $@
	echo "SET search_path TO $(SCHEMANAME), public;" >> $@
	echo "BEGIN;" >> $@
	awk -f uninstall.awk $< | tac >> $@
	echo "COMMIT;" >> $@

#assert.foo: utils.foo sql.foo

#date_time.foo: utils.foo assert.foo

#evolve.foo: utils.foo sql.foo auth.foo

auth.foo: utils.foo

#merge.foo: utils.foo assert.foo sql.foo

history.foo: utils.foo auth.foo
#history.foo: utils.foo auth.foo assert.foo

.PHONY: install uninstall doc clean test

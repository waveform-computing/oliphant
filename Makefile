DBNAME:=ark
SCHEMANAME:=utils

VERSION:=0.1
ALL_EXT:=
ALL_TESTS:=$(wildcard tests/*.sql)
ALL_SQL:=assert.sql auth.sql history.sql utils.sql
ALL_FOO:=$(ALL_SQL:%.sql=%.foo)

install: install.sql
	psql -d $(DBNAME) -f $<

uninstall: uninstall.sql
	psql -d $(DBNAME) -f $<

doc:
	$(MAKE) -C docs html

test:
	$(MAKE) -C tests test DBNAME=$(DBNAME) SCHEMANAME=$(SCHEMANAME)

clean: $(SUBDIRS)
	#$(MAKE) -C docs clean
	#$(MAKE) -C tests clean
	rm -f foo
	rm -f *.foo
	rm -f utils.sql
	rm -f install.sql
	rm -f uninstall.sql
	rm -fr build/ dist/

%.foo: %.sql
	sed -e 's/%SCHEMANAME%/$(SCHEMANAME)/' $< >> foo
	touch $@

install.sql: $(ALL_FOO)
	echo "\c $(DBNAME)" > $@
	echo "BEGIN;" >> $@
	cat foo >> $@
	echo "REVOKE ALL ON ALL TABLES IN SCHEMA $(SCHEMANAME) FROM public;" >> $@
	echo "REVOKE ALL ON ALL FUNCTIONS IN SCHEMA $(SCHEMANAME) FROM public;" >> $@
	echo "COMMIT;" >> $@
	rm foo
	rm -f *.foo

uninstall.sql: install.sql
	echo "\c $(DBNAME)" > $@
	echo "SET search_path TO $(SCHEMANAME), public;" >> $@
	awk -f uninstall.awk $< >> $@

assert.foo: utils.foo

#date_time.foo: utils.foo assert.foo

#evolve.foo: utils.foo sql.foo auth.foo

auth.foo: utils.foo

#merge.foo: utils.foo assert.foo sql.foo

history.foo: utils.foo auth.foo assert.foo

.PHONY: install uninstall doc clean test

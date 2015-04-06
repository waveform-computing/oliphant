DBNAME:=$(USER)

install:
	$(MAKE) -C assert install
	$(MAKE) -C auth install
	$(MAKE) -C history install
	$(MAKE) -C merge install

installdb:
	psql -d $(DBNAME) -c "CREATE EXTENSION assert"
	psql -d $(DBNAME) -c "CREATE EXTENSION auth"
	psql -d $(DBNAME) -c "CREATE EXTENSION history"
	psql -d $(DBNAME) -c "CREATE EXTENSION merge"

uninstalldb:
	psql -d $(DBNAME) -c "DROP EXTENSION merge"
	psql -d $(DBNAME) -c "DROP EXTENSION history"
	psql -d $(DBNAME) -c "DROP EXTENSION auth"
	psql -d $(DBNAME) -c "DROP EXTENSION assert"

uninstall:
	$(MAKE) -C assert uninstall
	$(MAKE) -C auth uninstall
	$(MAKE) -C history uninstall
	$(MAKE) -C merge uninstall

doc:
	$(MAKE) -C docs html

test:
	$(MAKE) -C tests test DBNAME=$(DBNAME)

.PHONY: install uninstall doc test


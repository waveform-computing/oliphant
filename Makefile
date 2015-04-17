DBNAME = $(USER)
PG_CONFIG = pg_config
MODULES = assert auth merge history

EXTENSION_DIR := $(shell $(PG_CONFIG) --sharedir)/extension

install:
	for m in $(MODULES); do \
		$(MAKE) -C $$m install; \
	done

uninstall:
	for m in $(MODULES); do \
		$(MAKE) -C $$m uninstall; \
	done

develop:
	for m in $(MODULES); do \
		for f in $$(find $$m -name "*.control") $$(find $$m -name "*.sql"); do \
			ln -s $$(readlink -e $$f) $(EXTENSION_DIR)/$$(basename $$f); \
		done; \
	done

installdb:
	for m in $(MODULES); do \
		psql -d $(DBNAME) -c "CREATE EXTENSION $$m"; \
	done

uninstalldb:
	for m in $(MODULES); do \
		psql -d $(DBNAME) -c "DROP EXTENSION $$m"; \
	done

doc:
	$(MAKE) -C docs html

test:
	$(MAKE) -C tests test DBNAME=$(DBNAME)

.PHONY: install uninstall doc test


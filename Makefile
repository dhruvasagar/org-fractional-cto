EMACS ?= emacs

# Run the ERT test suite in batch.
.PHONY: test
test:
	$(EMACS) -Q --batch -L . \
	  -l test/org-fractional-cto-actions-test.el \
	  -l test/org-fractional-cto-prospect-test.el \
	  -l test/org-fractional-cto-capture-test.el \
	  -l test/org-fractional-cto-people-test.el \
	  -l test/org-fractional-cto-scaffold-test.el \
	  -f ert-run-tests-batch-and-exit

# Regenerate the Texinfo manual from the Org sources under doc/.  straight.el
# (and MELPA) compile org-fractional-cto.texi -> .info at build time, so only
# the committed .texi needs to be up to date; run "make info" after editing any
# of the doc/*.org files.  doc/org-fractional-cto.org carries an
# #+EXPORT_FILE_NAME that writes the .texi to the repository root, which is
# where straight.el looks for top-level Info manuals.
.PHONY: info
info: org-fractional-cto.texi

org-fractional-cto.texi: doc/org-fractional-cto.org doc/guide.org doc/playbook.org doc/reference.org
	$(EMACS) -Q --batch \
	  --eval "(require 'ox-texinfo)" \
	  --eval "(setq org-export-with-broken-links t)" \
	  --visit doc/org-fractional-cto.org \
	  --eval "(org-texinfo-export-to-texinfo)"

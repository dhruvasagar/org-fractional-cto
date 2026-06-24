EMACS ?= emacs

# Run the ERT test suite in batch.
.PHONY: test
test:
	$(EMACS) -Q --batch -L . \
	  -l test/org-fractional-cto-actions-test.el \
	  -l test/org-fractional-cto-prospect-test.el \
	  -l test/org-fractional-cto-capture-test.el \
	  -l test/org-fractional-cto-people-test.el \
	  -l test/org-fractional-cto-ai-test.el \
	  -l test/org-fractional-cto-scaffold-test.el \
	  -f ert-run-tests-batch-and-exit

# Regenerate the Texinfo manual from the Org sources under docs/.  straight.el
# (and MELPA) compile org-fractional-cto.texi -> .info at build time, so only
# the committed .texi needs to be up to date; run "make info" after editing any
# of the docs/*.org files.  docs/org-fractional-cto.org carries an
# #+EXPORT_FILE_NAME that writes the .texi to the repository root, which is
# where straight.el looks for top-level Info manuals.
.PHONY: info
info: org-fractional-cto.texi

org-fractional-cto.texi: docs/org-fractional-cto.org docs/guide.org docs/playbook.org docs/reference.org
	$(EMACS) -Q --batch \
	  --eval "(require 'ox-texinfo)" \
	  --eval "(setq org-export-with-broken-links t)" \
	  --visit docs/org-fractional-cto.org \
	  --eval "(org-texinfo-export-to-texinfo)"

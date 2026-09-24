# The deny-all guard scans the whole repository; only local scratch and the framework checkout the
# deploy workflow makes are excluded, because neither is ever a deliverable.
GUARD_EXCLUDE := ^(\.tmp/|\.frameworks/)

.PHONY: fmt fmt-check lint iam-check pin-check verify-test allowlist-check ci

# Mutating: rewrites the value file in place.
fmt:
	terraform fmt terraform/prod.tfvars

fmt-check:
	@terraform fmt -check terraform/prod.tfvars > /dev/null || \
	{ echo "terraform/prod.tfvars is not fmt-clean; run 'make fmt'"; exit 1; }
	@# Against the empty tree, so every file is checked rather than only uncommitted changes.
	@# Markdown keeps trailing spaces as hard breaks; the markdownlint config is a byte-identical
	@# template mirror whose trailing blank line is not this repository's to change.
	@git diff --check "$$(git hash-object -t tree /dev/null)" -- . ':!*.md' ':!.markdownlint-cli2.jsonc' || \
	{ echo "whitespace errors; see above"; exit 1; }

lint:
	actionlint .github/workflows/*.yaml
	markdownlint-cli2 "README.md" "docs/**/*.md"

# The IAM documents are what the owner approves, so they must parse, and the manifest the apply
# commands read must name exactly the documents that exist: a policy, trust or control written but
# left out of the manifest would be approved and then never applied, and one the manifest names
# but nobody wrote would fail only at apply time.
iam-check:
	@for f in docs/reference/aws-iam/manifest.json docs/reference/aws-iam/*/*.json; do \
	  jq empty "$$f" || { echo "invalid JSON: $$f"; exit 1; }; \
	done
	@listed=$$(jq -r '.roles[].attached[], .roles[].trust, .controls[].document' \
	  docs/reference/aws-iam/manifest.json | sort); \
	present=$$(cd docs/reference/aws-iam && ls policies/*.json roles/*.trust.json controls/*.json | sort); \
	[ "$$listed" = "$$present" ] || { \
	  echo "manifest.json names:"; echo "$$listed"; echo "the directory holds:"; echo "$$present"; exit 1; }
	@printf 'iam-check: OK — every document parses and the manifest names exactly the documents present\n'

pin-check:
	@pin=$$(cat .github/terraform-framework-pin); \
	[ "$$(wc -l < .github/terraform-framework-pin)" -eq 1 ] && printf '%s' "$$pin" | grep -Eq '^[0-9a-f]{40}$$' || \
	{ echo ".github/terraform-framework-pin must hold exactly one 40-character SHA"; exit 1; }
	@printf 'pin-check: OK\n'

# The read-back decides whether a deploy is accepted and whether a scheduled check fails, so its
# decisions are proven offline against fixture responses.
verify-test:
	bash tools/test_verify_deployment.sh

allowlist-check:
	@ignored=$$(git ls-files --others --ignored --exclude-standard -- . 2>/dev/null \
	  | grep -vE '$(GUARD_EXCLUDE)' || true); \
	if [ -n "$$ignored" ]; then \
	  printf 'ERROR: repository files are NOT allowlisted in .gitignore:\n'; \
	  printf '%s\n' "$$ignored" | sed 's/^/  /'; exit 1; \
	fi
	@orphans=$$(grep '^!/' .gitignore | sed 's|^!/||' | while read -r p; do \
	  case "$$p" in \
	    */) git ls-files --cached --others --exclude-standard -- "$${p%/}" | grep -q . || echo "$$p" ;; \
	    *\**) ;; \
	    *)  git ls-files --error-unmatch "$$p" >/dev/null 2>&1 || echo "$$p" ;; \
	  esac; \
	done); \
	if [ -n "$$orphans" ]; then printf 'ERROR: .gitignore allowlists missing paths:\n%s\n' "$$orphans"; exit 1; fi
	@printf 'allowlist-check: OK\n'

ci:
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) iam-check
	$(MAKE) pin-check
	$(MAKE) verify-test
	$(MAKE) allowlist-check

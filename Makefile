# The deny-all guard scans the whole repository; only local scratch and the framework checkout the
# deploy workflow makes are excluded, because neither is ever a deliverable.
GUARD_EXCLUDE := ^(\.tmp/|\.frameworks/)

.PHONY: fmt fmt-check lint iam-check pin-check allowlist-check ci

# Mutating: the value file is HCL, and fmt only reads it from stdin under this name.
fmt:
	@formatted=$$(terraform fmt - < terraform/prod.tfvars) && \
	printf '%s\n' "$$formatted" > terraform/prod.tfvars

fmt-check:
	@terraform fmt -check - < terraform/prod.tfvars > /dev/null || \
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
# commands read must name exactly the policy files that exist: a policy written but left out of
# the manifest would be approved and then never attached.
iam-check:
	@for f in docs/reference/aws-iam/manifest.json docs/reference/aws-iam/*/*.json; do \
	  jq empty "$$f" || { echo "invalid JSON: $$f"; exit 1; }; \
	done
	@listed=$$(jq -r '.roles[].attached[]' docs/reference/aws-iam/manifest.json | sort); \
	present=$$(cd docs/reference/aws-iam && ls policies/*.json | sort); \
	[ "$$listed" = "$$present" ] || { \
	  echo "manifest.json attaches:"; echo "$$listed"; echo "policies/ holds:"; echo "$$present"; exit 1; }
	@printf 'iam-check: OK — every document parses and the manifest attaches every policy\n'

pin-check:
	@pin=$$(cat .github/terraform-framework-pin); \
	[ "$$(wc -l < .github/terraform-framework-pin)" -eq 1 ] && printf '%s' "$$pin" | grep -Eq '^[0-9a-f]{40}$$' || \
	{ echo ".github/terraform-framework-pin must hold exactly one 40-character SHA"; exit 1; }
	@printf 'pin-check: OK\n'

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
	$(MAKE) allowlist-check

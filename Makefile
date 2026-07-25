# AxiumPass — Smart Contract Security Pipeline
# Usage:
#   make install   # one-time: fetch forge-std + OpenZeppelin
#   make build     # compile contracts
#   make test      # run the full Foundry security suite (verbose)
#   make fuzz      # run with heavier fuzzing
#   make slither   # static analysis (requires: pip install slither-analyzer)
#   make audit     # build + test + slither (full pipeline)

.PHONY: install build test fuzz slither audit clean

install:
	forge install foundry-rs/forge-std --no-git || true
	forge install OpenZeppelin/openzeppelin-contracts --no-git || true

build:
	forge build

test:
	forge test -vv

fuzz:
	FOUNDRY_FUZZ_RUNS=2000 forge test -vv

slither:
	slither . --config-file slither.config.json

audit: build test slither

clean:
	forge clean

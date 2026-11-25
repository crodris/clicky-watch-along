# full-send pipeline profile
verify: tools/swift-check.sh && (cd worker && pnpm test && pnpm run typecheck)   # asked
merge-method: squash   # asked
reviewers: spec=neon+opus, final=sol   # trial: Neon next to Opus on Spec, Sol once per PR

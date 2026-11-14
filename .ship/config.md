# ship pipeline profile
verify: tools/swift-check.sh && (cd worker && pnpm test && pnpm run typecheck)   # asked
merge-method: squash   # asked

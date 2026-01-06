# Plan: Fix Gemini PKCE Multibyte Error

## Goal
Fix the deterministic runtime error in Gemini login by correctly handling binary data for PKCE verifiers and ensuring future coverage with property-based tests.

## Phase 1: Implementation Fix
- Refactor `benedict-provider-gemini--generate-verifier` to separate byte generation from verifier formatting.
- Implement `benedict-provider-gemini--make-verifier` which takes a list of bytes and returns a base64url encoded unibyte string.
- Update `benedict-provider-gemini--generate-verifier` to call the new helper.

## Phase 2: Testing Improvement
- Remove the narrow unit test `benedict-provider-gemini-generate-verifier-base64url`.
- Add `propcheck-deftest` in `test/benedict-provider-gemini-test.el` that:
  - Generates lists of 32 random integers (0-255).
  - Verifies `benedict-provider-gemini--make-verifier` produces a valid base64url string.
  - Verifies no "Multibyte character" error occurs for any input.

## Verification
- Run `nix run .#test -- benedict-provider-gemini`
- Verify 100 iterations of the property test pass.

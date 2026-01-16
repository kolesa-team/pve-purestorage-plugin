# PureStorage Plugin Tests

This directory contains tests for the PVE PureStorage Plugin.

## Test Structure

- `unit/` - Unit tests for individual functions
- `integration/` - Integration tests requiring actual PureStorage array
- `fixtures/` - Test data and mock responses
- `scripts/` - Helper scripts for testing

## Running Tests

```bash
# Run all unit tests
prove -v tests/unit/

# Run specific test
perl tests/unit/test_token_cache.t

# Run with verbose output
perl -I. tests/unit/test_command_validation.t
```

## Test Coverage

- Token caching and expiration
- Command path validation
- API request/response handling
- Device cleanup functions
- Error handling

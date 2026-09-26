.PHONY: format format-check analyze test

# Use the Dart formatter bundled with the active Flutter SDK.
format:
	dart format lib test

format-check:
	dart format --output=none --set-exit-if-changed lib test

analyze:
	flutter analyze

test:
	flutter test

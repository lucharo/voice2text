# Lint with ruff
lint:
    uv run ruff check --fix v2t/ tests/

# Fast checks; no models, microphone, or permissions needed
check: lint
    uv run python -m unittest -v tests.test_smoke
    uv run python -m v2t.config
    uv run python -m v2t.backends
    bash -n swiftbar/v2t.5s.sh

# Contributor benchmark harness (the dev group includes optional Whisper)
bench *args:
    uv run python -m v2t.bench {{args}}

# Build the package
build: check
    rm -rf dist/
    uv build
    uvx twine check dist/*

# Publish to PyPI (reads ~/.pypirc)
publish:
    uvx twine upload dist/*

# Build and publish only from a clean checkout
release:
    @test -z "$(git status --porcelain --untracked-files=all)" || (echo "working tree must be clean"; exit 1)
    just build
    just publish

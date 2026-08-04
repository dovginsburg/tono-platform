"""Static packaging invariants for the TWO backend Docker images.

There are two backend Dockerfiles, on purpose:

* ``apps/backend/Dockerfile.canonical`` — the CANONICAL production image. It is
  built from the repository ROOT (``docker build -f apps/backend/Dockerfile.canonical .``)
  so it can ``COPY`` the one committed commercial catalog
  (``packages/contracts/commercial-catalog.v1.json``), which lives OUTSIDE
  ``apps/backend``. This is the image published to GHCR and run by Render
  (``srv-d9gg8ngk1i2s738lngd0``); ``backend.catalog`` resolves the catalog to the
  exact path this image packages it at, so production never fails closed on a
  missing catalog.

* ``apps/backend/Dockerfile`` — the self-contained BACKEND-CONTEXT image. It is
  built with ``apps/backend`` as the Docker context and is what Railway staging
  (``railway up apps/backend --path-as-root`` in ``deploy-staging.yml``, keyed by
  ``apps/backend/railway.toml``'s ``dockerfilePath = "Dockerfile"``) and legacy
  manual deploys (``apps/backend/deploy.sh``) build. A ``COPY`` cannot reach
  ``packages/contracts`` from that context, so this image does NOT carry the
  catalog — exactly as it always has. It is retained UNCHANGED so those callers
  keep working; the canonical image is what carries the catalog.

Why both, and why this test: the canonical image MUST build from the repo root or
it silently ships without the catalog and the container fails closed the moment
anything reads it. The backend-context image MUST stay buildable from
``apps/backend`` or the active Railway staging deploy (and the legacy scripts)
break. This test — STATIC, no Docker daemon, runs in the default unit suite —
locks BOTH invariants against silent regression, plus the anti-drift guarantee
that the two images share one runtime environment and there is exactly ONE catalog
authority file (never duplicated into apps/backend to "fix" the context).

The live container behaviour is separately exercised by the opt-in Docker smokes
(``test_docker_cold_volume.py``, ``test_docker_backups_permission.py``), which
build the canonical image.
"""

from __future__ import annotations

import re
import shlex
from pathlib import Path, PurePosixPath

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
_BACKEND_DIR = _REPO_ROOT / "apps" / "backend"
_CANONICAL_DOCKERFILE = _BACKEND_DIR / "Dockerfile.canonical"
_LEGACY_DOCKERFILE = _BACKEND_DIR / "Dockerfile"
_DOCKERIGNORE = _REPO_ROOT / ".dockerignore"

# Repo-root-relative source of the ONE committed catalog and the exact absolute
# runtime path the canonical image must expose it at (matches production's
# TONO_COMMERCIAL_CATALOG_PATH and the in-container computed default).
_CATALOG_REL = "packages/contracts/commercial-catalog.v1.json"
_RUNTIME_CATALOG_PATH = PurePosixPath("/") / _CATALOG_REL

# The backend package is copied here in BOTH images; the app runs `uvicorn
# backend.server:app` from WORKDIR /app, so `backend.catalog` lives at
# /app/backend/catalog.py in either layout.
_IMAGE_BACKEND_DIR = PurePosixPath("/app/backend")

# Every file that issues a CANONICAL backend-image `docker build` (repo-root
# context + Dockerfile.canonical). If a new site is added it must appear here (the
# count assertion below trips otherwise) AND satisfy the repo-root invariant.
_CANONICAL_BUILD_SITE_FILES = (
    ".github/workflows/ci.yml",
    ".github/workflows/deploy-staging.yml",
    ".github/workflows/publish-backend-image.yml",
    "scripts/ci/docker_cold_volume_smoke.sh",
    "scripts/ci/docker_backups_permission_smoke.sh",
)

# Tokens that legitimately denote "the repository root" as a build context.
_REPO_ROOT_CONTEXT_TOKENS = {".", "$REPO_ROOT", "${REPO_ROOT}"}

# The canonical Dockerfile's basename, as referenced by -f/--file.
_CANONICAL_BASENAME = "Dockerfile.canonical"


# ---------------------------------------------------------------------------
# Dockerfile parsing helpers
# ---------------------------------------------------------------------------
def _logical_lines(dockerfile_text: str) -> list[str]:
    """Return every non-comment, non-blank Dockerfile instruction as one logical
    line, joining backslash line-continuations."""
    logical: list[str] = []
    pending = ""
    for raw in dockerfile_text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if pending:
            line = pending + " " + line
            pending = ""
        if line.endswith("\\"):
            pending = line[:-1].rstrip()
            continue
        logical.append(line)
    if pending:
        logical.append(pending)
    return logical


def _copy_directives(dockerfile_text: str) -> list[tuple[list[str], str]]:
    """Return [(sources, dest), ...] for every COPY. Build-arg flags
    (``--chown=``/``--chmod=``) are stripped so only real path operands remain."""
    directives: list[tuple[list[str], str]] = []
    for line in _logical_lines(dockerfile_text):
        if not line.upper().startswith("COPY "):
            continue
        operands = [t for t in line[len("COPY ") :].split() if not t.startswith("--")]
        if len(operands) >= 2:
            *sources, dest = operands
            directives.append((sources, dest))
    return directives


def _runtime_env_instructions(dockerfile_text: str) -> list[str]:
    """Every instruction that defines the runtime ENVIRONMENT — i.e. all logical
    instructions EXCEPT COPY — with internal whitespace normalized. The two
    Dockerfiles legitimately differ only in their COPY sources (and the canonical
    image's extra catalog COPY); everything else must be identical."""
    return [
        " ".join(line.split())
        for line in _logical_lines(dockerfile_text)
        if not line.upper().startswith("COPY ")
    ]


def _read(rel: str) -> str:
    return (_REPO_ROOT / rel).read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# CANONICAL image: catalog is packaged at the exact runtime path
# ---------------------------------------------------------------------------
def test_canonical_dockerfile_copies_catalog_to_runtime_path():
    """The canonical Dockerfile must COPY the committed catalog, by its
    repo-root-relative path, to the exact absolute runtime path — once,
    unmodified."""
    copies = _copy_directives(_CANONICAL_DOCKERFILE.read_text(encoding="utf-8"))
    catalog_copies = [(srcs, dest) for srcs, dest in copies if _CATALOG_REL in srcs]
    assert len(catalog_copies) == 1, (
        "expected exactly one COPY of the committed catalog "
        f"{_CATALOG_REL!r}; found {catalog_copies!r}"
    )
    sources, dest = catalog_copies[0]
    assert sources == [_CATALOG_REL], (
        f"catalog COPY must have a single repo-root-relative source; got {sources!r}"
    )
    assert PurePosixPath(dest) == _RUNTIME_CATALOG_PATH, (
        f"catalog must be packaged at {_RUNTIME_CATALOG_PATH} (production's "
        f"TONO_COMMERCIAL_CATALOG_PATH and the computed default); got {dest!r}"
    )


def test_canonical_dockerfile_copies_backend_and_requirements_from_repo_root():
    """In the canonical image the backend tree and requirements must be COPYd by
    their repo-root-relative paths (proving a repo-root build context), never the
    apps/backend-context forms `COPY . ...` / `COPY requirements.txt ...` that
    drop the catalog."""
    copies = _copy_directives(_CANONICAL_DOCKERFILE.read_text(encoding="utf-8"))
    sources_seen = [s for srcs, _ in copies for s in srcs]

    assert ["apps/backend"] in [srcs for srcs, _ in copies], (
        f"expected `COPY apps/backend <dest>`; COPY sources were {sources_seen!r}"
    )
    assert "apps/backend/requirements.txt" in sources_seen, (
        "requirements must be copied by its repo-root-relative path "
        f"apps/backend/requirements.txt; sources were {sources_seen!r}"
    )

    # Every COPY source must be repo-root-relative (under apps/backend or
    # packages/). A bare `.` or `requirements.txt` means an apps/backend context.
    for src in sources_seen:
        assert not src.startswith("/"), f"unexpected absolute COPY source {src!r}"
        assert src.split("/", 1)[0] in {"apps", "packages"}, (
            f"COPY source {src!r} is not repo-root-relative — a build with the "
            "apps/backend context would silently drop the catalog"
        )
    assert "." not in sources_seen and "requirements.txt" not in sources_seen, (
        "found an apps/backend-context COPY form (`.` or `requirements.txt`) in the "
        "canonical Dockerfile; it must use the repository root as context"
    )


def test_canonical_backend_copied_two_dirs_below_root_matching_catalog_rule():
    """Coherence: applying `backend.catalog`'s OWN path rule to the canonical
    image layout must resolve to the packaged catalog.

    `backend.catalog` computes its default as ``Path(__file__).parents[N] /
    <catalog rel>`` where N is the depth of the backend package below its root.
    The canonical Dockerfile copies `apps/backend` (2 levels) to `/app/backend`
    (also 2 levels below `/`), so the SAME index that yields the repo root in the
    dev tree yields `/` in the image, and the join lands on the packaged file.
    This ties the code's magic index, the backend COPY dest, and the catalog COPY
    dest together — change any one incoherently and this fails.
    """
    copies = _copy_directives(_CANONICAL_DOCKERFILE.read_text(encoding="utf-8"))

    backend_dests = [dest for srcs, dest in copies if srcs == ["apps/backend"]]
    assert backend_dests, "no `COPY apps/backend <dest>` directive found"
    image_backend_dir = PurePosixPath(backend_dests[0])
    assert image_backend_dir == _IMAGE_BACKEND_DIR, (
        f"backend must be copied to {_IMAGE_BACKEND_DIR}/ (so `uvicorn "
        f"backend.server:app` and catalog.py's path rule line up); got {image_backend_dir}"
    )

    # Depth of the backend package below its root == the parents[] index the code
    # must use. Derive it from the repo-root-relative source, don't hardcode.
    depth = len(PurePosixPath("apps/backend").parts)  # == 2

    # The number in catalog.py must equal that depth (locks the magic index).
    src = (_BACKEND_DIR / "catalog.py").read_text(encoding="utf-8")
    m = re.search(r"parents\[(\d+)\]\s*/\s*[\"']packages[\"']", src)
    assert m, "could not find the parents[N] catalog default-path expression"
    assert int(m.group(1)) == depth, (
        f"catalog.py uses parents[{m.group(1)}] but the backend sits {depth} dirs "
        "below its root; the in-image default would not resolve to the catalog"
    )

    # In the DEV tree, that rule resolves to the real committed catalog.
    import backend.catalog as catalog

    assert catalog._DEFAULT_CATALOG_PATH == _REPO_ROOT / _CATALOG_REL
    assert catalog._DEFAULT_CATALOG_PATH.is_file()

    # In the IMAGE, the same rule (parents[depth] of /app/backend/catalog.py)
    # resolves to exactly the packaged catalog path.
    image_catalog_py = image_backend_dir / "catalog.py"
    image_root = image_catalog_py.parents[depth]
    image_default = image_root / _CATALOG_REL
    assert image_default == _RUNTIME_CATALOG_PATH, (
        f"in-image default {image_default} != packaged catalog {_RUNTIME_CATALOG_PATH}"
    )


def test_committed_catalog_source_exists_and_loads():
    """The exact file the canonical Dockerfile COPYs must exist and pass catalog
    validation — so we never ship (or fail to ship) a broken authority file."""
    import backend.catalog as catalog

    source = _REPO_ROOT / _CATALOG_REL
    assert source.is_file(), f"catalog COPY source missing: {source}"
    # load_catalog() validates the launch invariants; raises CatalogError if bad.
    data = catalog.load_catalog()
    assert data["catalog_version"], "catalog has no version"
    assert "revenuecat" in data["providers"], (
        "catalog must carry the RevenueCat provider block the webhook maps against"
    )


# ---------------------------------------------------------------------------
# BACKEND-CONTEXT (legacy/Railway) image: self-contained, no catalog, no reach
# outside apps/backend — retained compatibility.
# ---------------------------------------------------------------------------
def test_legacy_dockerfile_is_backend_context_self_contained():
    """`apps/backend/Dockerfile` must build from the apps/backend CONTEXT: every
    COPY source resolves INSIDE apps/backend (never `apps/backend/...`,
    `packages/...`, or an absolute path), and it copies the backend tree via
    `COPY . /app/backend/`. This is exactly what `railway up apps/backend
    --path-as-root` (+ railway.toml `dockerfilePath = "Dockerfile"`) and the legacy
    deploy.sh build; a repo-root-relative source here would break them."""
    copies = _copy_directives(_LEGACY_DOCKERFILE.read_text(encoding="utf-8"))
    sources_seen = [s for srcs, _ in copies for s in srcs]
    assert sources_seen, "legacy Dockerfile has no COPY directives"

    for src in sources_seen:
        assert not src.startswith("/"), f"unexpected absolute COPY source {src!r}"
        top = src.split("/", 1)[0]
        assert top not in {"apps", "packages"}, (
            f"legacy Dockerfile COPY source {src!r} is repo-root-relative — a "
            "`railway up apps/backend` (apps/backend context) build cannot resolve "
            "it. The backend-context image must stay self-contained."
        )

    # Positively: it copies the whole backend context to /app/backend/ (so
    # catalog.py lands at /app/backend/catalog.py, matching the canonical layout).
    assert (["."], "/app/backend/") in copies, (
        f"legacy Dockerfile must `COPY . /app/backend/`; COPYs were {copies!r}"
    )


def test_legacy_dockerfile_does_not_package_the_catalog():
    """The backend-context image cannot reach packages/contracts, so it must NOT
    attempt to COPY the catalog — and there must be no second catalog file smuggled
    into apps/backend to make it reachable (single catalog authority)."""
    copies = _copy_directives(_LEGACY_DOCKERFILE.read_text(encoding="utf-8"))
    for srcs, _dest in copies:
        for src in srcs:
            assert "commercial-catalog" not in src and "packages/contracts" not in src, (
                f"legacy Dockerfile must not COPY the catalog (src {src!r}); the "
                "canonical image is the ONLY image that packages it"
            )
    # No duplicate catalog authority hiding inside apps/backend.
    dupes = list(_BACKEND_DIR.rglob("commercial-catalog.v1.json"))
    assert dupes == [], (
        f"the catalog must live ONLY at {_CATALOG_REL}; found duplicate(s) under "
        f"apps/backend: {dupes!r}"
    )


# ---------------------------------------------------------------------------
# Anti-drift: the two images share ONE runtime environment
# ---------------------------------------------------------------------------
def test_canonical_and_legacy_dockerfiles_share_runtime_environment():
    """The two Dockerfiles must differ ONLY in their COPY sources (and the
    canonical image's extra catalog COPY). Every other instruction — base image,
    apt packages, ENV, the user/entrypoint setup, EXPOSE, ENTRYPOINT, CMD — must be
    byte-for-byte identical, so the catalog-carrying production image and the
    backend-context staging image can never silently diverge on how they run."""
    canonical_env = _runtime_env_instructions(
        _CANONICAL_DOCKERFILE.read_text(encoding="utf-8")
    )
    legacy_env = _runtime_env_instructions(_LEGACY_DOCKERFILE.read_text(encoding="utf-8"))
    assert canonical_env == legacy_env, (
        "canonical and legacy Dockerfiles have diverged on a non-COPY instruction; "
        "they must share one runtime environment.\n"
        f"canonical-only: {[i for i in canonical_env if i not in legacy_env]}\n"
        f"legacy-only:    {[i for i in legacy_env if i not in canonical_env]}"
    )


# ---------------------------------------------------------------------------
# Every CANONICAL backend image build uses repo-root context + Dockerfile.canonical
# ---------------------------------------------------------------------------
def _docker_build_commands(text: str) -> list[list[str]]:
    """Return each `docker build ...` invocation as a token list, joining
    backslash line-continuations and honoring shell quoting."""
    commands: list[list[str]] = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        stripped = lines[i].strip()
        if stripped.startswith("docker build"):
            buf = [stripped]
            while buf[-1].rstrip().endswith("\\") and i + 1 < len(lines):
                i += 1
                buf.append(lines[i].strip())
            joined = " ".join(seg.rstrip("\\").strip() for seg in buf)
            try:
                tokens = shlex.split(joined)
            except ValueError:
                tokens = joined.split()
            commands.append(tokens)
        i += 1
    return commands


def _flag_value(tokens: list[str], *names: str) -> str | None:
    for idx, tok in enumerate(tokens):
        if tok in names and idx + 1 < len(tokens):
            return tokens[idx + 1]
        for name in names:
            if tok.startswith(name + "="):
                return tok.split("=", 1)[1]
    return None


def _is_backend_build(tokens: list[str]) -> bool:
    """A backend-image build: it names the backend Dockerfile via -f/--file, or
    tags the tono-backend image."""
    dockerfile = _flag_value(tokens, "-f", "--file") or ""
    if "apps/backend/Dockerfile" in dockerfile or "BACKEND_DIR" in dockerfile:
        return True
    return any("tono-backend" in t for t in tokens)


def test_every_canonical_backend_build_uses_repo_root_context_and_canonical_dockerfile():
    """No backend image may be built with `apps/backend` as the Docker context —
    that context cannot see packages/contracts and silently drops the catalog.
    Every `docker build` site must pass the CANONICAL Dockerfile via -f/--file and a
    repo-root context (`.` in the workflows, `$REPO_ROOT` in the smokes)."""
    found = 0
    for rel in _CANONICAL_BUILD_SITE_FILES:
        text = _read(rel)
        builds = [c for c in _docker_build_commands(text) if _is_backend_build(c)]
        assert builds, f"{rel}: expected a backend `docker build` invocation, found none"
        for tokens in builds:
            found += 1
            dockerfile = _flag_value(tokens, "-f", "--file")
            assert dockerfile is not None, (
                f"{rel}: backend build must pass -f/--file <Dockerfile.canonical>; "
                f"tokens={tokens}"
            )
            assert dockerfile.endswith(_CANONICAL_BASENAME), (
                f"{rel}: -f must point at the CANONICAL Dockerfile "
                f"({_CANONICAL_BASENAME}); got {dockerfile!r}. The backend-context "
                "apps/backend/Dockerfile does NOT package the catalog."
            )
            assert "apps/backend" in dockerfile or "BACKEND_DIR" in dockerfile, (
                f"{rel}: -f must reference the backend Dockerfile path; got {dockerfile!r}"
            )

            # The context is the final operand; it must be the repo root.
            context = tokens[-1]
            assert context in _REPO_ROOT_CONTEXT_TOKENS, (
                f"{rel}: build context must be the repo root "
                f"{sorted(_REPO_ROOT_CONTEXT_TOKENS)}; got {context!r} (tokens={tokens})"
            )
            assert "apps/backend" not in context and "BACKEND_DIR" not in context, (
                f"{rel}: apps/backend must not be the build context; got {context!r}"
            )

    assert found >= len(_CANONICAL_BUILD_SITE_FILES), (
        f"expected >= {len(_CANONICAL_BUILD_SITE_FILES)} canonical backend builds "
        f"guarded, found {found}"
    )


# ---------------------------------------------------------------------------
# Retained STAGING/LEGACY compatibility: Railway (+ legacy deploy.sh) build the
# backend-context Dockerfile from apps/backend, and must NOT be pointed at the
# repo-root canonical image (whose COPY sources they cannot resolve).
# ---------------------------------------------------------------------------
def _toml_value(text: str, key: str) -> str | None:
    m = re.search(rf'^\s*{re.escape(key)}\s*=\s*"([^"]*)"', text, re.MULTILINE)
    return m.group(1) if m else None


def test_railway_toml_targets_the_backend_context_dockerfile():
    """apps/backend/railway.toml must keep building the self-contained
    backend-context Dockerfile (`dockerfilePath = "Dockerfile"`, relative to the
    apps/backend upload root), NOT Dockerfile.canonical — whose repo-root-relative
    COPY sources a `railway up apps/backend` build cannot satisfy."""
    text = _read("apps/backend/railway.toml")
    assert _toml_value(text, "builder") == "DOCKERFILE", (
        "railway.toml must use the DOCKERFILE builder"
    )
    dockerfile_path = _toml_value(text, "dockerfilePath")
    assert dockerfile_path == "Dockerfile", (
        "railway.toml dockerfilePath must be the backend-context `Dockerfile` "
        f"(relative to apps/backend); got {dockerfile_path!r}. Pointing it at "
        "Dockerfile.canonical would break the Railway build (repo-root COPY sources)."
    )
    assert _CANONICAL_BASENAME not in text, (
        "railway.toml must not reference the repo-root canonical Dockerfile"
    )


def test_staging_deploy_uses_backend_context_railway_root():
    """The live Railway staging deploy step uploads apps/backend as the build root
    (`railway up apps/backend --path-as-root`), which pairs with railway.toml's
    backend-context `dockerfilePath = "Dockerfile"`. This is the affected caller a
    repo-root Dockerfile edit must not break, so lock it explicitly."""
    text = _read(".github/workflows/deploy-staging.yml")
    assert re.search(r"railway\s+up\s+apps/backend\s+--path-as-root", text), (
        "deploy-staging.yml must deploy Railway staging with "
        "`railway up apps/backend --path-as-root` (apps/backend build root)"
    )
    # The Railway deploy must not be re-pointed at a repo-root canonical build.
    railway_lines = [ln for ln in text.splitlines() if "railway up" in ln]
    for ln in railway_lines:
        assert _CANONICAL_BASENAME not in ln and "railway up ." not in ln, (
            f"Railway staging deploy must stay backend-context; got {ln.strip()!r}"
        )


def test_legacy_manual_deploy_stays_backend_context():
    """apps/backend/deploy.sh is a legacy manual Railway deploy run from the backend
    directory (bare `railway up`, backend context). It must not be silently coupled
    to the repo-root canonical image."""
    text = _read("apps/backend/deploy.sh")
    assert re.search(r"^\s*railway\s+up\b", text, re.MULTILINE), (
        "deploy.sh is expected to invoke `railway up` (backend-context deploy)"
    )
    assert _CANONICAL_BASENAME not in text, (
        "legacy deploy.sh must not reference Dockerfile.canonical; it builds the "
        "self-contained backend-context apps/backend/Dockerfile"
    )


# ---------------------------------------------------------------------------
# .dockerignore keeps the needed paths, drops secrets (canonical repo-root context)
# ---------------------------------------------------------------------------
def _dockerignore_patterns() -> list[str]:
    lines = []
    for raw in _DOCKERIGNORE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            lines.append(line)
    return lines


def test_dockerignore_exists_and_preserves_required_paths():
    """`.dockerignore` must exist at the repo root (the canonical build context)
    and must NEVER exclude the two things the canonical image needs: the backend
    tree and the catalog."""
    assert _DOCKERIGNORE.is_file(), (
        "repo-root .dockerignore is required for the canonical root build context"
    )
    patterns = _dockerignore_patterns()

    forbidden_exclusions = {
        "apps/backend",
        "apps/backend/",
        "apps/backend/**",
        "apps/backend/*",
        _CATALOG_REL,
        "packages",
        "packages/",
        "packages/**",
        "packages/contracts",
        "packages/contracts/",
    }
    for pat in patterns:
        neg = pat.lstrip("!").strip()
        assert neg not in forbidden_exclusions, (
            f".dockerignore pattern {pat!r} would exclude a path the image needs "
            "(the backend tree or the committed catalog)"
        )


def test_dockerignore_drops_secrets_and_heavy_sibling_apps():
    """Positively lock the context-hygiene intent: env/secret files and the heavy
    sibling app trees are excluded so nothing secret is baked and the context
    stays small."""
    patterns = set(_dockerignore_patterns())
    for needed in ("**/.env", "**/.env.*", ".git"):
        assert needed in patterns, f".dockerignore must exclude {needed!r} (secret/context hygiene)"
    for heavy in ("apps/ios", "apps/android", "apps/web"):
        assert heavy in patterns, f".dockerignore must exclude the heavy sibling tree {heavy!r}"

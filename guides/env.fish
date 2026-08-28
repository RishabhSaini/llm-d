#!/usr/bin/env fish
# Shared environment variables for all llm-d guides.
# Source this file in your shell before running guide commands:
#   source $REPO_ROOT/guides/env.fish

if not set -q REPO_ROOT
  set -gx REPO_ROOT (realpath (git rev-parse --show-toplevel 2>/dev/null) 2>/dev/null)
end

### Release Versions for grabbing CRDs
# The *_URL variables are recomputed on every source; a *_URL value exported
# beforehand is discarded. To pin a release, export the matching *_VERSION.
if not set -q GATEWAY_API_VERSION
  set -gx GATEWAY_API_VERSION latest
end

if test "$GATEWAY_API_VERSION" = "latest"
  set -gx GATEWAY_API_URL releases/latest/download
else
  set -gx GATEWAY_API_URL "releases/download/$GATEWAY_API_VERSION"
end

# Controls which release of Gateway API Inference Extension to grab CRDs from
if not set -q GAIE_VERSION
  set -gx GAIE_VERSION latest
end

if test "$GAIE_VERSION" = "latest"
  set -gx GAIE_URL releases/latest/download
else
  set -gx GAIE_URL "releases/download/$GAIE_VERSION"
end

# Controls which release of llm-d/llm-router to grab CRDs from. Used in flowcontrol guide
if not set -q ROUTER_RELEASE_VERSION
  set -gx ROUTER_RELEASE_VERSION latest
end

if test "$ROUTER_RELEASE_VERSION" = "latest"
  set -gx ROUTER_RELEASE_URL releases/latest/download
else
  set -gx ROUTER_RELEASE_URL "releases/download/$ROUTER_RELEASE_VERSION"
end

### Chart versions and OCI coordinates for router chart
if not set -q ROUTER_CHART_VERSION
  set -gx ROUTER_CHART_VERSION v0
end

if not set -q ROUTER_STANDALONE_CHART
  set -gx ROUTER_STANDALONE_CHART "oci://ghcr.io/llm-d/charts/llm-d-router-standalone"
end

if not set -q ROUTER_GATEWAY_CHART
  set -gx ROUTER_GATEWAY_CHART "oci://ghcr.io/llm-d/charts/llm-d-router-gateway"
end

### Container Image coordinates and tag for router chart
if not set -q ROUTER_EPP_VERSION
  set -gx ROUTER_EPP_VERSION main
end

if not set -q ROUTER_EPP_IMAGE
  set -gx ROUTER_EPP_IMAGE "ghcr.io/llm-d/llm-d-router-endpoint-picker"
end

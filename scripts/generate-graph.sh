#!/usr/bin/env bash
# Generates a NuGet dependency graph via nugraph, invoked from the
# "Generate dependency graph" step in action.yml. Reads its configuration
# from environment variables set by that step (PROJECT_PATH, OUTPUT_PATH,
# JOB_SUMMARY, JOB_SUMMARY_TITLE, TITLE, INCLUDE_VERSIONS, DIRECTION,
# NO_LINKS, IGNORE_PATTERNS, HIDE_EMPTY_GRAPHS, EXTRA_ARGS) plus
# GITHUB_STEP_SUMMARY from the runner environment.
set -eo pipefail

# Matches the title input's default in action.yml. A composite action input
# left unset falls back to its declared default, indistinguishable from the
# user explicitly passing an empty string -- both arrive here as TITLE="".
# Defaulting title to this sentinel instead of "" lets the two be told apart:
# unset (sentinel) omits -t so nugraph applies its own default title, while
# an explicit empty string is passed through as -t "" so nugraph omits the
# title entirely.
readonly TITLE_UNSET='::unset::'

resolve_job_summary_default() {
  if [[ -z "$JOB_SUMMARY" ]]; then
    # Auto: default to a job summary when there's no artifact to
    # otherwise show the graph came from.
    [[ -z "$OUTPUT_PATH" ]] && JOB_SUMMARY="true" || JOB_SUMMARY="false"
  fi
}

validate_inputs() {
  if [[ -z "$OUTPUT_PATH" && "$JOB_SUMMARY" != "true" ]]; then
    echo "::error::Set at least one of 'output-path' or 'job-summary' -- otherwise this action has nothing to do." >&2
    exit 1
  fi
}

parse_ignore_flags() {
  ignore_flags=()
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] && ignore_flags+=(-i "$pattern")
  done <<< "$IGNORE_PATTERNS"
  return 0
}

# Passed as an array (rather than folded into EXTRA_ARGS) so values
# containing spaces -- namely TITLE -- work, unlike extra-args which is
# word-split unquoted.
build_common_flags() {
  common_flags=()
  [[ "$TITLE" != "$TITLE_UNSET" ]] && common_flags+=(-t "$TITLE")
  [[ "$INCLUDE_VERSIONS" == "true" ]] && common_flags+=(-s)
  [[ -n "$DIRECTION" ]] && common_flags+=(-d "$DIRECTION")
  [[ "$NO_LINKS" == "true" ]] && common_flags+=(--no-links)
  return 0
}

# nugraph has no concept of solution files -- it only understands a single
# project (or a directory containing exactly one). Expand a .sln/.slnx into
# its member .csproj/.fsproj/.vbproj entries here and run nugraph once per
# project, since that's the only way to get a graph out of a solution at
# all. `dotnet sln list` is used rather than parsing the solution file
# ourselves, since it understands both the classic .sln format and the newer
# XML-based .slnx format. A plain project-path is left untouched and keeps
# behaving exactly as before (one file, one summary section, no name
# suffix).
expand_projects() {
  project_paths=()
  project_names=()
  local lower_path="${PROJECT_PATH,,}"
  if [[ "$lower_path" == *.sln || "$lower_path" == *.slnx ]]; then
    is_solution=true
    local sln_dir rel_path project_name
    sln_dir="$(dirname "$PROJECT_PATH")"
    while IFS= read -r rel_path; do
      [[ -z "$rel_path" ]] && continue
      rel_path="${rel_path//\\//}"
      project_paths+=("$sln_dir/$rel_path")
      project_name="$(basename "$rel_path")"
      project_names+=("${project_name%.*}")
    done < <(dotnet sln "$PROJECT_PATH" list | grep -iE '\.(cs|fs|vb)proj$')

    if [[ ${#project_paths[@]} -eq 0 ]]; then
      echo "::error::No .csproj/.fsproj/.vbproj projects found in solution file '$PROJECT_PATH'." >&2
      exit 1
    fi
  else
    is_solution=false
    project_paths=("$PROJECT_PATH")
    project_names=("")
  fi
}

# nugraph's --output always writes raw graph source (Mermaid text for
# .mmd/.mermaid, Graphviz DOT text otherwise) -- it never renders an image
# itself when --output is given. For image extensions, render the Graphviz
# DOT source locally with Graphviz's `dot` instead.
detect_dot_requirement() {
  need_dot=false
  if [[ -n "$OUTPUT_PATH" ]]; then
    case "${OUTPUT_PATH,,}" in
      *.svg|*.png|*.pdf|*.jpg|*.jpeg) need_dot=true ;;
    esac
    if [[ "$need_dot" == "true" ]] && ! command -v dot >/dev/null 2>&1; then
      sudo apt-get update -qq
      sudo apt-get install -y --no-install-recommends graphviz
    fi
  fi
}

# An empty graph is one whose Mermaid text has nothing left over once the
# fixed frontmatter/comment/graph-declaration/classDef boilerplate is
# stripped out -- i.e. no root node and no dependency nodes.
is_empty_graph() {
  local mermaid_file="$1"
  ! grep -vE '^(---|title:|%%|graph |classDef |[[:space:]]*$)' "$mermaid_file" | grep -q .
}

write_job_summary() {
  local project_name="$1" mermaid_file="$2"
  {
    if [[ -n "$project_name" ]]; then
      echo "### ${JOB_SUMMARY_TITLE} -- ${project_name}"
    else
      echo "### ${JOB_SUMMARY_TITLE}"
    fi
    echo '```mermaid'
    cat "$mermaid_file"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
}

write_output() {
  local project_path="$1" output_path="$2"
  mkdir -p "$(dirname "$output_path")"
  if [[ "$need_dot" == "true" ]]; then
    local graph_source render_format
    graph_source="$(mktemp --suffix=.gv)"
    nugraph "$project_path" "${ignore_flags[@]}" "${common_flags[@]}" $EXTRA_ARGS --output "$graph_source"
    render_format="${output_path##*.}"
    render_format="${render_format,,}"
    [[ "$render_format" == "jpeg" ]] && render_format="jpg"
    dot "-T$render_format" "$graph_source" -o "$output_path"
    rm -f "$graph_source"
  else
    nugraph "$project_path" "${ignore_flags[@]}" "${common_flags[@]}" $EXTRA_ARGS --output "$output_path"
  fi
}

process_project() {
  local project_path="$1" project_name="$2"

  # A Mermaid probe is generated whenever we need to check for emptiness,
  # even if the final output is a rendered image, since its plain-text
  # structure is the simplest to inspect.
  local mermaid_source=""
  if [[ "$JOB_SUMMARY" == "true" || "$HIDE_EMPTY_GRAPHS" == "true" ]]; then
    mermaid_source="$(mktemp --suffix=.mmd)"
    nugraph "$project_path" "${ignore_flags[@]}" "${common_flags[@]}" $EXTRA_ARGS --output "$mermaid_source"
  fi

  if [[ "$HIDE_EMPTY_GRAPHS" == "true" ]] && is_empty_graph "$mermaid_source"; then
    echo "Skipping empty graph for ${project_name:-$(basename "$project_path")}"
    rm -f "$mermaid_source"
    return
  fi

  [[ "$JOB_SUMMARY" == "true" ]] && write_job_summary "$project_name" "$mermaid_source"
  [[ -n "$mermaid_source" ]] && rm -f "$mermaid_source"

  if [[ -n "$OUTPUT_PATH" ]]; then
    # For a solution, suffix each project's output with its name
    # (graph.svg -> graph.MyApp.svg) so per-project files don't collide --
    # applied unconditionally for .sln input so filenames stay predictable
    # even if a project is later added or removed.
    local output_path
    if [[ "$is_solution" == "true" ]]; then
      output_path="${OUTPUT_PATH%.*}.${project_name}.${OUTPUT_PATH##*.}"
    else
      output_path="$OUTPUT_PATH"
    fi
    write_output "$project_path" "$output_path"
  fi
}

main() {
  resolve_job_summary_default
  validate_inputs
  parse_ignore_flags
  build_common_flags
  expand_projects
  detect_dot_requirement

  for i in "${!project_paths[@]}"; do
    process_project "${project_paths[$i]}" "${project_names[$i]}"
  done
}

main

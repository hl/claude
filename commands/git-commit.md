# Git Commit

Create a properly formatted conventional commit following established project standards.

1. **Pre-commit Quality Checks**
   - For Elixir projects: Run `mix format <file>` on all modified Elixir files (.ex, .exs)
   - Run `mix compile --warnings-as-errors` to ensure no compilation warnings
   - Run `mix credo --strict --format=json` if Credo is available in the project
   - Run `mix dialyzer` if Dialyzer is available in the project
   - Run project tests before committing; abort if tests fail

2. **Analyze Changes**
   - Review git status and git diff to understand what changed
   - Determine appropriate conventional commit type (feat, fix, docs, style, refactor, test, chore)
   - Identify the scope of changes

3. **Create Commit Message**
   - Follow conventional commit structure:
     ```
     type(scope): description
     
     - Detailed explanation of changes
     - Include reasoning for changes
     - Reference original prompts if applicable
     
     Changes were generated based on the following prompts:
     1. "Original prompt text"
     2. "Additional prompt context"
     ```

4. **Execute Commit**
   - Stage all modified files
   - Commit with the properly formatted message
   - Confirm successful commit

5. **GitHub Operations**
   - Always use `gh` CLI for GitHub-related tasks (issues, PRs, checks, releases)
   - Never use web URLs for GitHub operations when `gh` is available

## Example Commit Message

```
feat(auth): implement user authentication system

- Added secure token-based authentication
- Implemented login/logout functionality
- Added user session management
- Included proper error handling for invalid credentials

Changes were generated based on the following prompts:
1. "Add user authentication using Phoenix.Token"
2. "Ensure secure session management"
```
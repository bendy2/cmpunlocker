# Contributing

Thanks for your interest in contributing to cmpunlocker! This guide covers submitting changes.

---

## Submitting Changes

1. **Fork the repo** on GitHub

2. **Create a branch** for your changes:
   ```bash
   git checkout -b feature/my-improvement
   ```

3. **Make changes** and test thoroughly on real hardware

4. **Commit with clear messages**:
   ```bash
   git commit -m "Add improvement to 8GB card support"
   ```

5. **Push and open a PR**:
   ```bash
   git push origin my-feature
   ```

6. **Describe your changes** in the PR body (following the PR template)

---

## Code Style & Conventions

- **Patch files**: Use unified diff format (`git diff` or `patch -u`). Include context lines.
- **Bash scripts**: Strict mode (`set -euo pipefail`), quote variables, error checking.
- **Comments in patches**: Use standard patch comments (`---` and `+++` headers); C comments go in the patched code.
- **Testing**: Always test on physical hardware before submitting. Describe your test environment (distro, kernel version, card variant).

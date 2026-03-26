# 🤝 Contributing Guidelines

Thank you for your interest in contributing to **PVE-Logscript**!

This project is designed to automate the collection of support logs for Proxmox VE systems. Contributions are highly appreciated and help improve stability, security, and usability.


## 📌 Table of Contents

- General Rules
- Creating Issues
- Pull Requests
- Coding Guidelines
- Testing
- Commit Messages
- Security
- Documentation
- License


## ⚖️ General Rules

- Be respectful and constructive
- Discuss major changes via an issue before implementation
- Keep contributions small and focused
- Always include documentation where applicable


## 🐞 Creating Issues

Before opening a new issue, please check if a similar one already exists.

A good issue should include:

- Clear description of the problem
- Steps to reproduce
- Expected behavior
- Actual behavior
- System information:
  - Proxmox VE version
  - Kernel version
  - Hardware (optional)


## 🔀 Pull Requests

### Requirements

- Fork the repository
- Create a feature branch:

```bash
git checkout -b feature/your-feature-name
```

### Guidelines

- Provide a clear description of your changes
- Reference related issues (if applicable)
- Avoid unnecessary changes (e.g. formatting-only commits)

### Workflow

1. Fork the repository  
2. Implement your changes  
3. Test thoroughly  
4. Submit a pull request  


## 💻 Coding Guidelines

As this project is based on shell scripting:

- Prefer POSIX-compliant code where possible
- Use strict mode:

```bash
set -euo pipefail
```

- Implement proper error handling
- Use clear and descriptive variable names
- Comment complex logic

### Example

```bash
#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/tmp/pve-logs"

mkdir -p "$LOG_DIR"
```


## 🧪 Testing

Please test your changes on:

- Proxmox VE 8.x (if applicable) / 9.x
- Different storage setups (e.g. ZFS, Ceph if possible)

Ensure:

- The script runs without errors
- Logs are collected correctly
- No sensitive data is unintentionally exposed


## 📝 Commit Messages

Use clear and structured commit messages.

### Format

type(scope): short description

### Examples

- fix(log): handle missing journalctl  
- feat(output): add gzip compression  
- docs(readme): update usage section  


## 🔒 Security

- Do not hardcode sensitive data
- Carefully review which logs are exported
- Avoid insecure external calls


## 📚 Documentation

- Update the README when necessary
- Document new features
- Provide examples when helpful


## 📄 License

By contributing, you agree that your contributions will be licensed under the project's existing license (LGPL-2.1).


## 🙌 Thank You

Every contribution—whether it's a bug fix, feature, or documentation—is appreciated.

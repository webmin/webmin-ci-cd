&nbsp;

<p align="center"><img src="https://github.com/user-attachments/assets/8043ab5b-77ec-43bf-9adb-84619b18e0dc" alt="Webmin CI/CD logo" width="360px"></p>
<br>
<p align="center"> <a href="https://github.com/webmin/webmin-ci-cd/stargazers"><img src="https://img.shields.io/github/stars/webmin/webmin-ci-cd" alt="Stars"></a> <a href="https://github.com/webmin/webmin-ci-cd/network/members"><img src="https://img.shields.io/github/forks/webmin/webmin-ci-cd" alt="Members"></a> <a href="https://github.com/webmin/webmin-ci-cd/contributors/"><img src="https://img.shields.io/github/contributors/webmin/webmin-ci-cd" alt="Contributors"></a> <a href="https://github.com/webmin/webmin-ci-cd/issues/"><img src="https://img.shields.io/github/issues-raw/webmin/webmin-ci-cd" alt="Issues"></a> <a href="https://github.com/webmin/webmin-ci-cd/blob/master/LICENCE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a> </p>

---

## About
This repository provides CI/CD pipelines to automate the building and distribution of Webmin modules and Virtualmin plugins. The system produces unstable builds for developers to test the latest code updates and pre-release builds for users to try upcoming releases before they appear in stable repositories.

## Objective

The goal of this automation is to make building and distributing Webmin modules and Virtualmin plugins easy and reliable, enabling developers and users always have access to the latest updates and features without needing to handle everything manually.

Even though GitHub Actions is used to manage builds, the entire process is handled by scripts within this repository. These scripts—around 2,500 lines of carefully written and tested Bash code—give us full control over the build process. This setup isn't tied to GitHub, making it possible to run the same code seamlessly on other platforms like GitLab or even a local machine. This approach makes the system flexible, portable, and easy to migrate without being locked into any single platform.

## Design

The repositories design works to make accessing and managing packages as straightforward as possible. Each repository provides a clean, single-page list of built packages, allowing users to download packages manually by simply clicking on the package name. This makes finding and grabbing the package you need quick and easy without navigating through multiple confusing pages and directories.

To support a wide range of systems, the repositories provide packages for all major architectures, including older ones like i386 (i686), popular options like amd64 (x86_64), and the increasingly widespread arm64 (aarch64).

Despite providing a single directory for all architectures, modern package managers like APT and DNF handle this effortlessly, automatically picking the correct package for installation. Since only one package is architecture-dependent, splitting repositories by architecture would add unnecessary complexity without any real advantage.

All repositories and packages are signed with the Webmin Developers signing key, the same one used for standard Webmin installations. This makes configuration straightforward, with just a single repository file and a simple, easy-to-remember URL.

In the unstable repositories, only the latest package versions are kept, with older ones removed on every push. The pre-release repositories, on the other hand, keep all versions so users can go back to older releases if needed.

## Versioning
The repositories use a structured versioning system to differentiate between unstable and pre-release packages while maintaining consistency with production repositories.

For unstable repositories, the versioning always follows the full semantic format with three numeric segments separated by periods. The last segment, usually reserved for bug fixes, is replaced with a timestamp in `YYYYMMDDHHMM` format. This creates a version like `7.30.202501111200`, where the timestamp reflects the exact build time.

For pre-release repositories, the package version is derived directly from the module or plugin itself. These versions may use standard versioning, like `7.30.4`, or other schemes, such as `3.6`, depending on the package.

For RPM-based packages, some include an epoch due to historical reasons. The epoch is consistent with production repositories, providing full compatibility across unstable, pre-release, and production repositories. This consistency allows packages to seamlessly replace one another based solely on their version, regardless of the repository they originate from.

## Workflows

Currently, we use GitHub Actions to manage builds, which brings several advantages. As mentioned earlier, we intentionally avoid relying on third-party projects beyond GitHub Actions to keep the build process independent and easily migratable to other platforms if needed.

At the core of the system is a master workflow, which is also stored in this repository. This master workflow is the single source of truth, containing all the logic for builds. There are no additional templates for Webmin modules or Virtualmin plugins, making it straightforward to manage. Any changes to the build process only need to be made in the master workflow.

Each product repository includes a child workflow that reuses the master workflow. The primary role of the child workflow is to define when builds should be triggered, such as on a push to a specific branch or when a release is created. Additionally, the child workflow is responsible for passing repository-specific secrets to the master workflow. This is necessary because, for security reasons, GitHub restricts the sharing of secrets across organizations and user accounts, requiring each child workflow located elsewhere to explicitly set and pass its own secrets.

In some cases, fine-grained tokens are required for builds involving private repositories. For instance, if changes in a public repository rely on a private one, GitHub's permission model prevents workflows from accessing the private repository unless an additional token with the necessary permissions is provided for cloning the private repository. Conversely, when a workflow is triggered directly by a private repository, GitHub automatically provides an authentication token, making it easy to clone the repository without any additional steps.

## Architecture
This is a quick overview of the key files involved in the build process, highlighting their roles, functionality, and purpose.

- **bootstrap.bash** — this script bootstraps the build process by downloading and preparing all necessary dependencies and files required for the build. It acts as the single entry point to initiate the build, making it easier to make changes to the project. Additionally, it loads essential environment variables and includes all required functions.

- **environment.bash** — this script configures and exports the environment variables needed for the build, some of which are derived from the GitHub Actions workflow. It controls verbosity and determines the build type based on parameters passed by the calling script.

- **functions.bash** — this script includes all the functions used throughout the build process, with over two dozen functions.

- **build-product-deb.bash**, **build-product-rpm.bash**, **build-module-deb.bash**, **build-module-rpm.bash** — these scripts are designed specifically to handle builds for either a product (e.g., Webmin or Usermin) or a plugin (e.g., Virtualmin GPL, Virtualmin Nginx, Virtualmin AWStats, etc.). They are called directly from the workflow and manage the build process for the respective product or plugin.

- **sync-github-secrets.bash** — this script dynamically updates, deletes, or lists GitHub secrets for a given repository or all repositories. It's especially useful for batch updating secrets across all projects in one go. The script expects a ZIP file containing the secrets, either specified via the `ENV_SECRETS_ZIP` environment variable or placed in `~/Git/.secrets/gh-secrets.zip` file.

  The ZIP file should follow a specific structure where secrets are named using the file format `organization__SECRET_NAME`.

  For example:

  - `webmin__UPLOAD_SSH_DIR`: Sets `UPLOAD_SSH_DIR` secret for `webmin` organization for all repositories listed in the `webmin_repos` variable
  - `virtualmin__IP_KNOWN_HOSTS`: Sets `IP_KNOWN_HOSTS` secret for `virtualmin` organization for all repositories listed in the `virtualmin_repos` variable

- **github-actions.bash** - this is a forced-command wrapper script for secure automated repository operations over SSH. It allows specific commands like repository signing with strict path checks and SCP uploads only to the given directory, while denying interactive shells, SFTP, SCP downloads, and all other commands. This ensures that only authorized operations can be performed by the CI/CD system, enhancing security.

- **sign-repo.bash** — this script signs and builds repositories on a remote system. It's called at the final stage of the workflow, after all packages have been uploaded to the remote server. It's versatile and can be reused independently.

- **sign-all-repos.bash** - this script allows for manually signing and building all repositories or a specific repository. It's useful for situations where you need to re-sign packages or update repository metadata without going through the entire build process again.

- **sync-remote-repos.bash** - this script performs a full mirror sync from the staging environment to the repository server. This makes sure the repository server is identical to the staging environment.

- **repo-auth-check.bash** - this helper script checks a username and password with a web service and allows or denies access, caching recent successes to avoid repeated calls during page loads.

- **repo-auth-check.php** - this is an HTTP endpoint for license validation, designed to be called by `mod_authnz_external` via a bash script on the repository server. The script checks credentials against a MariaDB database and verifies that the license hasn't expired, considering a configurable grace period.

- **module-groups.txt** — this text file defines groups of modules that need to be rebuilt if certain modules are changed. For instance, changes in the Virtualmin GPL module will trigger a rebuild of the Virtualmin Pro package.

- **modules-mapping.txt** — this text file provides a mapping between repository names and package names, addressing cases where the package name differs from the repository name. It also allows configuration of the package edition, license type, and other options, such as the package target directory.

- **modules-build-flags.txt** — this text file contains build flags for each module, allowing customization of the build process on a per-module basis.

- **rpm-modules-epoch.txt** — this text file lists the epoch values for each RPM package that needs one.

- **install-ci-cd-repo.sh** — this script installs the unstable or prerelease repository on the system, making it simple for developers and users to access the latest packages.

## Repositories

### **Webmin unstable repository**
- **URL**: [download.webmin.dev](https://download.webmin.dev)
- **Description**:
  - Unstable packages for Webmin and Usermin, including the latest changes to Authentic Theme
  - Built automatically on each push to the master branch of Webmin, Usermin, or Authentic Theme
  - Intended for **developers** who need early access to the latest code updates

- **Installation**:
  ```bash
  curl -fsSL https://download.webmin.dev/install | sh -s -- webmin unstable
  ```

### **Webmin pre-release repository**
- **URL**: [rc.download.webmin.dev](https://rc.download.webmin.dev)
- **Description**:
  - Pre-release packages for Webmin and Usermin, including the latest Authentic Theme release
  - Built automatically when a tagged release is created for Webmin or Usermin
  - Intended for **users** who want to try upcoming features before the final release

- **Installation**:
  ```bash
  curl -fsSL https://download.webmin.dev/install | sh -s -- webmin prerelease
  ```

### **Virtualmin unstable repository**
- **URL**: [download.virtualmin.dev](https://download.virtualmin.dev)
- **Description**:
  - Unstable packages for Virtualmin and its plugins
  - Built automatically on each push to the master branch of Virtualmin or its plugins
  - Intended for **developers** who need early access to the latest code updates

- **Installation**:
  ```bash
  curl -fsSL https://download.virtualmin.dev/install | sh -s -- virtualmin unstable
  curl -fsSL https://download.virtualmin.dev/install | sh -s -- virtualmin prerelease
  ```

### **Virtualmin pre-release repository**
- **URL**: [rc.download.virtualmin.dev](https://rc.download.virtualmin.dev)
- **Description**:
  - Pre-release packages for Virtualmin and its plugins
  - Built automatically when a tagged release is created for any Virtualmin or its plugins
  - Intended for **users** who want to try upcoming features before the final release

- **Installation**:
  ```bash
  curl -fsSL https://rc.download.virtualmin.dev/install | sh -s -- virtualmin prerelease
  ```

## Screenshots

<img width="203" alt="Webmin Development Unstable Repo Screenshot" src="https://github.com/user-attachments/assets/27103e7f-9245-4d7c-8472-a2d0c482a927#gh-light-mode-only" /> <img width="203" alt="Webmin Development Prerelease Repo Screenshot" src="https://github.com/user-attachments/assets/12f04707-466d-4391-a73b-72842adfd849#gh-light-mode-only" /> <img width="203" alt="Virtualmin Development Unstable Repo Screenshot" src="https://github.com/user-attachments/assets/75f2cc9c-05ca-42d6-9b1c-6b8bf30cd244#gh-light-mode-only" /> <img width="203" alt="Virtualmin Development Prerelease Repo Screenshot" src="https://github.com/user-attachments/assets/eda03493-ac6c-4289-b8eb-454d009e9471#gh-light-mode-only" />

<img width="203" alt="Webmin Development Unstable Repo Screenshot" src="https://github.com/user-attachments/assets/b737c81d-49c4-4214-bb37-9df162cb0569#gh-dark-mode-only" /> <img width="203" alt="Webmin Development Prerelease Repo Screenshot" src="https://github.com/user-attachments/assets/f342149a-9404-4e8b-b343-31c2de39df10#gh-dark-mode-only" /> <img width="203" alt="Virtualmin Development Unstable Repo Screenshot" src="https://github.com/user-attachments/assets/a86f8f7b-ef50-4905-9cf8-2261d9496715#gh-dark-mode-only" /> <img width="203" alt="Virtualmin Development Prerelease Repo Screenshot" src="https://github.com/user-attachments/assets/d379450b-2d86-44b2-9d96-39b414185399#gh-dark-mode-only" />

## License

This project is licensed under the MIT License.

## Contributions

Contributions are welcome! Please submit pull requests or open issues for feature requests or bug reports.

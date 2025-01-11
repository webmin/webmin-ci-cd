&nbsp;

<p align="center"><img src="https://github.com/user-attachments/assets/8d78f545-3fc3-4479-bb05-da3b893c1d2b" alt="Webmin" width="340px"></p>
<p align="center"><img src="https://github.com/user-attachments/assets/2cfc176a-d6e9-4b06-8866-c2b2c5622dc8" alt="Webmin" width="240px"></p>

<p align="center"> <a href="https://github.com/webmin/webmin-ci-cd/stargazers"><img src="https://img.shields.io/github/stars/webmin/webmin-ci-cd" alt="Stars"></a> <a href="https://github.com/webmin/webmin-ci-cd/network/members"><img src="https://img.shields.io/github/forks/webmin/webmin-ci-cd" alt="Members"></a> <a href="https://github.com/webmin/webmin-ci-cd/contributors/"><img src="https://img.shields.io/github/contributors/webmin/webmin-ci-cd" alt="Contributors"></a> <a href="https://github.com/webmin/webmin-ci-cd/issues/"><img src="https://img.shields.io/github/issues-raw/webmin/webmin-ci-cd" alt="Issues"></a> <a href="https://github.com/webmin/webmin-ci-cd/blob/master/LICENCE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a> </p>

---

## About
This repository provides CI/CD pipelines to automate the building and distribution of Webmin modules and Virtualmin plugins. The system produces unstable builds for developers to test the latest code updates and pre-release builds for users to try upcoming releases before they appear in stable repositories.

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
- **URL**: [software.virtualmin.dev](https://software.virtualmin.dev)
- **Description**:
  - Unstable packages for Virtualmin and its plugins
  - Built automatically on each push to the master branch of Virtualmin or its plugins
  - Intended for **developers** who need early access to the latest code updates

- **Installation**:
  ```bash
  curl -fsSL https://software.virtualmin.dev/install | sh -s -- virtualmin unstable
  ```

### **Virtualmin pre-release repository**
- **URL**: [rc.software.virtualmin.dev](https://rc.software.virtualmin.dev)
- **Description**:
  - Pre-release packages for Virtualmin and its plugins
  - Built automatically when a tagged release is created for any Virtualmin or its plugins
  - Intended for **users** who want to try upcoming features before the final release

- **Installation**:
  ```bash
  curl -fsSL https://software.virtualmin.dev/install | sh -s -- virtualmin prerelease
  ```

## Screenshots

<img width="249" alt="Webmin Development Unstable Repo Screenshot" src="https://github.com/user-attachments/assets/27103e7f-9245-4d7c-8472-a2d0c482a927#gh-light-mode-only" /> <img width="249" alt="Webmin Development Prerelease Repo Screenshot" src="https://github.com/user-attachments/assets/12f04707-466d-4391-a73b-72842adfd849#gh-light-mode-only" /> <img width="249" alt="Virtualmin Development Unstable Repo Screenshot" src="https://github.com/user-attachments/assets/75f2cc9c-05ca-42d6-9b1c-6b8bf30cd244#gh-light-mode-only" /> <img width="249" alt="Virtualmin Development Prerelease Repo Screenshot" src="https://github.com/user-attachments/assets/eda03493-ac6c-4289-b8eb-454d009e9471#gh-light-mode-only" />

<img width="249" alt="Webmin Development Unstable Repo Screenshot" src="https://github.com/user-attachments/assets/b737c81d-49c4-4214-bb37-9df162cb0569#gh-dark-mode-only" /> <img width="249" alt="Webmin Development Prerelease Repo Screenshot" src="https://github.com/user-attachments/assets/f342149a-9404-4e8b-b343-31c2de39df10#gh-dark-mode-only" /> <img width="249" alt="Virtualmin Development Unstable Repo Screenshot" src="https://github.com/user-attachments/assets/a86f8f7b-ef50-4905-9cf8-2261d9496715#gh-dark-mode-only" /> <img width="249" alt="Virtualmin Development Prerelease Repo Screenshot" src="https://github.com/user-attachments/assets/d379450b-2d86-44b2-9d96-39b414185399#gh-dark-mode-only" />


## License

This project is licensed under the MIT License.

## Contributions

Contributions are welcome! Please submit pull requests or open issues for feature requests or bug reports.

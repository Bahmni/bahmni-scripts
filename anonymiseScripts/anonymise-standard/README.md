

# SQL Scripts for Data Anonymisation

These SQL scripts are designed to **mask or anonymise sensitive data** across Bahmni modules — **OpenMRS**, **OpenELIS**, and **Odoo (10 & 16)** — enabling safe use of production-like datasets in **staging, demo, or training environments** while remaining privacy-compliant.

---

## ⚙️ How to Execute

### 1) OpenMRS Database

Copy the script to the `openmrsdb` container and run:

```bash
docker compose exec -it openmrsdb sh
mysql -uroot -padminAdmin!123 openmrs < /mask_openmrs_sensitive_data.sql
```

### 2) OpenELIS Database

Copy the script to the `openelisdb` container and run:

```bash
docker compose exec -it openelisdb sh
psql -U clinlims -d clinlims < /mask_openelis_sensitive_data.sql
```

### 3) Odoo Database (10 & 16)

Copy the script to the `odoodb` container and run the respective version:

**Odoo 16:**

```bash
docker compose exec -it odoodb sh
psql -U odoo -d odoo < /mask_odoo16_sensitive_data.sql
```

**Odoo 10:**

```bash
docker compose exec -it odoodb sh
psql -U odoo -d odoo < /mask_odoo10_sensitive_data.sql
```

---

## 📌 Overview of Scripts

| Script Name                        | Application  | Purpose                                                                                       |
| ---------------------------------- | ------------ | --------------------------------------------------------------------------------------------- |
| `mask_openmrs_sensitive_data.sql`  | **OpenMRS**  | Masks patient identifiers, names, addresses, phone numbers, and other PII.                    |
| `mask_openelis_sensitive_data.sql` | **OpenELIS** | Anonymises patient-related data while preserving test result links.                           |
| `mask_odoo16_sensitive_data.sql`   | **Odoo 16**  | Masks customer, supplier, and employee information (names, emails, phone numbers, addresses). |
| `mask_odoo10_sensitive_data.sql`   | **Odoo 10**  | Masks customer, supplier, and employee information in Odoo 10.                                |

---

## 🧠 Purpose

These scripts allow organizations using Bahmni to:

* Work with **realistic datasets** for testing, development, or training.
* Ensure **no personally identifiable information (PII)** is exposed in non-production environments.
* Comply with **data protection and privacy regulations**.

---



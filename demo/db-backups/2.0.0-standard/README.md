# Bahmni Standard 1.0.0 Database Backup Images
This directory contains the artifacts used to publish the database backup images for OpenMRS, OpenELIS and Odoo.

### Changes done on OpenMRS Database
Use mysql:8.0 as the database image while starting up Bahmni. The CIEL and other import happens from Initializer module.

- Navigate to OpenMRS --> Administration --> Manage Providers --> Neha Anand. Update practitioner type and set available for appointments to true.
- Assign roles for `doctor`, `registration` users.
- Set saleable attribute to procedures using the [script](../../../metadataScripts/openmrs/set_saleable_attribute.sh)


### Changes done on Odoo database
Use postgres:16 as the database image while starting up Bahmni. Odoo initializes all the required schema.

- Update Company Information --> Name, Currency
- Create a user named `emrsync` for Atomfeed sync
- Enable Custom toggles under Settings --> Bahmni 
- Under Settings --> Sales, enable Unit of Measure and Advanced Pricelist
- Under Settings --> Inventory, enable Tracking by Lots and Expiration data and also Storage Locations


Once doing all these updates take backup using the `backup_bahmni_standard.sh` script in the bahmni-docker/bahmni-standard repository. Copy over all the required artefacts into respective resources directory of applications.

Note: Remove `bahmniforms` directory in the configuration_checksums directory.
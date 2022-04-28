## Test data generator
---
---
This program creates patient and encounter CSV files which can be uploaded into app using admin console-> import feature.

It uses java-faker library to crate random data. Its using Java 8.


### How to run the program
---
---
Run "TestDataGenApp".
Enter the number of patient registration needed.
Choose 'y' or 'n' if you need encounter CSV.
Enter the percentage of profiles need to have encounter information. You need to put number only. Don`t put %.
On successful execution, two CSV files will be created in target/output folder. Now you are ready import them into app.

In src/main/resource folder you can find config.yaml file.
Here you can change output file names, patient registration index start number and registration number initials.

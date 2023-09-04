# CSV Restore

#### Note: Not to be used in production. Only for demo/ testing purposes.

This directory contains a script file which can be used to restore patient and encounter csv files into an environment.

## How to use:
1. Open the script file and update the variables for the path of the CSV files. By default it looks for patients.csv and encounters.csv in the current directory.
2. Update the value of `LOCATION_COOKIE` variable. Defaults to Bahmni Clinic location of lite environment. If you want to load encounters to a different location, yo ucan get the cookie value by going to the inspect window of the browser and logging in with the required location.
3. Update the value of `HOST` variable if you want to upload in some other environment other than local.


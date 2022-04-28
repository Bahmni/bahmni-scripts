import com.opencsv.exceptions.CsvException;

import java.io.IOException;
import java.text.ParseException;
import java.util.Arrays;
import java.util.List;
import java.util.Scanner;

public class TestDataGenApp {

    public static void main(String args[])
    {
        PatientProfile patientProfile = new PatientProfile();
        boolean bCreateContact = false;
        int contactCount = 0;
        Scanner scanner = new Scanner(System.in);
        System.out.println("Enter the number of patient profiles needed: ");
        int patientProfileCount = scanner.nextInt();
        System.setProperty("total", String.valueOf(patientProfileCount));
        System.out.println("Do you need contact csv to be created? (y/n):");
        String sCreateContact = scanner.next();

        if(sCreateContact.equalsIgnoreCase("y")|| !sCreateContact.equalsIgnoreCase("n")) {
            System.out.println("Enter the percentage of profiles need to have contacts from above");
            int contactCountPercentage = scanner.nextInt();
            contactCount = patientProfileCount * contactCountPercentage / 100;
            bCreateContact = true;
        }

        try {
            patientProfile.writePatientProfileInCSV(patientProfileCount);

            if(bCreateContact) {
                ContactProfile contactProfile = new ContactProfile();
                contactProfile.writeContactProfileInCSV(contactCount);
            }

            System.out.println("****************************************************************");
            System.out.println("Congratulations. The csvs are created at target/output folder.");
            System.out.println("****************************************************************");

        } catch (IOException e) {
            System.out.println("Something went wrong.");
            System.out.println(e.getLocalizedMessage());
        } catch (CsvException e) {
            throw new RuntimeException(e);
        } catch (ParseException e) {
            throw new RuntimeException(e);
        }

    }
}

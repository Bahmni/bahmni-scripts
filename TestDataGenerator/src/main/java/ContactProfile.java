import com.opencsv.CSVReader;
import com.opencsv.CSVReaderBuilder;
import com.opencsv.exceptions.CsvException;

import java.io.FileReader;
import java.io.IOException;
import java.text.ParseException;
import java.time.LocalDate;
import java.time.Period;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class ContactProfile {

     protected List<String[]> getShuffledPatientProfilesToObject() throws IOException, CsvException {
          FileReader patientRegFile = new FileReader(Constant.patientProfileFileName);
          CSVReader csvReader = new CSVReaderBuilder(patientRegFile)
                  .withSkipLines(1)
                  .build();
          List<String[]> allPatientProfileData = csvReader.readAll();

          Collections.shuffle(allPatientProfileData);
          return allPatientProfileData;
     }

     private List<String[]> setContactProfiles(int count) throws IOException, CsvException, ParseException {
          List<String[]> entries = new ArrayList<>();
          String[] tempPatientInfo;
          String[] tempContactInfo;
          String encounterType="Consultation";
          String visitType="OPD";
          String patientName;

          String[] header = {"Registration Number","encounterType","visitType","Patient.Name","Patient.AGE",
                  "Patient.Gender","Patient.Village","Visit Start Date","Visit End Date","Repeat.1.EncounterDate",
                  "Repeat.1.Obs.Chief Complaint Duration","Repeat.1.Obs.Chief Complaint Notes",
                  "Repeat.1.Obs.History Notes","Repeat.1.Obs.Examination Notes","Repeat.1.Obs.Smoking History",
                  "Repeat.1.Diagnosis.1","Repeat.1.Condition.1","Repeat.1.Obs.Consultation Note",
                  "Repeat.1.Obs.Hospital Course", "Repeat.1.Obs.Operative Notes, Condition",
                  "Repeat.1.Obs.Operative Notes, Procedure","Repeat.1.Obs.Procedure Notes, Diagnosis"};

          entries.add(header);
          List<String[]> patientList = getShuffledPatientProfilesToObject();
          for(int i=0;i<count;i++)
          {
               tempPatientInfo = patientList.get(i);
               patientName = tempPatientInfo[2]+ " "+tempPatientInfo[3]+" "+tempPatientInfo[4];
               tempContactInfo = new String[]{tempPatientInfo[0],encounterType,visitType,patientName,
                       String.valueOf(getPatientAge(tempPatientInfo[6])),tempPatientInfo[5],tempPatientInfo[9],
                       tempPatientInfo[1],tempPatientInfo[1],
                       tempPatientInfo[1],"12","Test notes","history notes","exam notes","yes","Fever",
                       "Infectious diarrhea", "Testing Consultation Note","Testing hospital course comment","Stable",
                       "Wound Care", "Need dressing"};
               entries.add(tempContactInfo);
          }
          return entries;
     }

     protected void writeContactProfileInCSV(int count) throws IOException, ParseException, CsvException {
          DataWriter dataWriter = new DataWriter();
          String fileName = Constant.contactProfileFileName;
          List<String[]> profiles = setContactProfiles(count);
          dataWriter.writeDataIntoCSV(profiles, fileName);
     }
     private int getPatientAge(String dob) throws ParseException {
          LocalDate birthday = LocalDate.parse(dob);
          LocalDate today = LocalDate.now();
          Period period = Period.between(birthday, today);
          return period.getYears();
     }
}

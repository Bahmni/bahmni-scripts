import org.yaml.snakeyaml.Yaml;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.InputStream;
import java.util.Map;

public class Constant {
    static String patientProfileFileName = getProperties().get("patientProfileFileName").toString();
    static String contactProfileFileName = getProperties().get("contactProfileFileName").toString();
    static int registrationIndexStartPoint = (Integer) getProperties().get("registrationIndexStartPoint");
    static String patientRegistrationStartDay = getProperties().get("patientRegistrationStartDay").toString();
    static String regInitial = getProperties().get("regInitial").toString();

    public static Map<String, Object> getProperties() {
        Map<String, Object> data;
        try {
            InputStream inputStream = new FileInputStream(new File("src/main/resources/config.yaml"));
            Yaml yaml = new Yaml();
            data = yaml.load(inputStream);

        } catch (FileNotFoundException e) {
            throw new RuntimeException(e);
        }
        return data;
    }
}

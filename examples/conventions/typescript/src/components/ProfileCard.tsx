export function ProfileCard({ userId }: { userId: string }) {
  const { t } = useTranslation();
  const [user, setUser] = useState<User | null>(null);
  useEffect(() => {
    api.users.get(userId).then(setUser);
  }, [userId]);
  if (!user) return <Spinner label={t("profile.loading")} />;
  return <h2>{user.name}</h2>;
}
